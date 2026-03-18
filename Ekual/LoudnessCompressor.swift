import Foundation
import Accelerate

// Real-time safe loudness compressor that mimics Windows Loudness Equalization.
// All methods are designed for use on the audio real-time thread:
// no allocations, no locks, no ObjC dispatch.
//
// Uses block-based processing: the envelope is tracked per-block (32 frames),
// and gain is applied to the entire block at once using vDSP SIMD operations.
// This cuts expensive math calls (sqrtf, log10f, expf) by ~32x compared to
// per-sample processing, while being perceptually transparent (0.67ms blocks at 48kHz).

struct LoudnessCompressor {

    // MARK: - Parameters

    /// Target RMS level in dBFS. Audio is compressed toward this level.
    var targetLevelDb: Float = -24.0

    /// Compression ratio (e.g. 12 means 12:1).
    var ratio: Float = 12.0

    /// Soft knee width in dB. Smooths the transition around the threshold.
    var kneeWidthDb: Float = 6.0

    /// Attack time in seconds. How fast gain reduces for loud signals.
    var attackTime: Float = 0.005

    /// Release time in seconds. How slowly gain recovers after a loud peak.
    var releaseTime: Float = 1.0 {
        didSet { updateCoefficients() }
    }

    /// Makeup gain in dB applied after compression to bring up quiet content.
    var makeupGainDb: Float = 12.0 {
        didSet { makeupLinear = powf(10.0, makeupGainDb / 20.0) }
    }

    // MARK: - Internal State

    /// Current smoothed envelope level in linear amplitude.
    private var envelopeLevel: Float = 0.0

    /// Current smoothed gain in dB (used for attack/release smoothing).
    private var smoothedGainDb: Float = 0.0

    /// Pre-computed linear makeup gain (updated when makeupGainDb changes).
    private var makeupLinear: Float = 1.0

    /// Sample rate used for coefficient calculation.
    private var sampleRate: Float = 44100.0

    /// Pre-computed attack coefficient (per-sample).
    private var attackCoeff: Float = 0.0

    /// Pre-computed release coefficient (per-sample).
    private var releaseCoeff: Float = 0.0

    /// Pre-computed attack coefficient for block-level smoothing.
    private var blockAttackCoeff: Float = 0.0

    /// Pre-computed release coefficient for block-level smoothing.
    private var blockReleaseCoeff: Float = 0.0

    /// Number of frames per processing block.
    private let blockSize: Int = 32

    // MARK: - Lookahead Ring Buffer
    // 2-block lookahead (~1.3ms at 48kHz) for predictive envelope tracking.
    // The envelope detector sees upcoming transients before the audio is output,
    // preventing audible pumping on sudden loud sounds.

    private let lookaheadBlocks: Int = 2

    /// Pre-allocated ring buffer holding lookaheadBlocks slots of audio.
    private var ringBuffer: UnsafeMutablePointer<Float>?

    /// RMS value for each slot in the ring buffer.
    private var ringRMS: UnsafeMutablePointer<Float>?

    /// Number of samples per ring buffer slot (blockSize * channelCount).
    private var ringSlotSize: Int = 0

    /// Current write position in the ring buffer.
    private var ringWriteIndex: Int = 0

    /// True once the ring buffer has been fully filled at least once.
    private var ringPrimed: Bool = false

    // MARK: - Initialization

    init(sampleRate: Float = 44100.0) {
        self.sampleRate = sampleRate
        self.makeupLinear = powf(10.0, makeupGainDb / 20.0)
        updateCoefficients()
    }

    // MARK: - Coefficient Calculation

    private mutating func updateCoefficients() {
        // Per-sample coefficients
        if attackTime > 0 && sampleRate > 0 {
            attackCoeff = expf(-1.0 / (attackTime * sampleRate))
        } else {
            attackCoeff = 0.0
        }
        if releaseTime > 0 && sampleRate > 0 {
            releaseCoeff = expf(-1.0 / (releaseTime * sampleRate))
        } else {
            releaseCoeff = 0.0
        }

        // Block-level coefficients: equivalent to applying per-sample coeff blockSize times
        // coeff_block = coeff_sample ^ blockSize
        let bs = Float(blockSize)
        blockAttackCoeff = powf(attackCoeff, bs)
        blockReleaseCoeff = powf(releaseCoeff, bs)
    }

    mutating func setSampleRate(_ rate: Float) {
        sampleRate = rate
        updateCoefficients()
    }

    // MARK: - Lookahead Lifecycle

    /// Allocate the lookahead ring buffer. Called once on first process call.
    private mutating func initializeLookahead(channelCount: Int) {
        let slotSize = blockSize * channelCount
        let totalFloats = lookaheadBlocks * slotSize

        let buf = UnsafeMutablePointer<Float>.allocate(capacity: totalFloats)
        buf.initialize(repeating: 0.0, count: totalFloats)
        ringBuffer = buf

        let rms = UnsafeMutablePointer<Float>.allocate(capacity: lookaheadBlocks)
        rms.initialize(repeating: 0.0, count: lookaheadBlocks)
        ringRMS = rms

        ringSlotSize = slotSize
        ringWriteIndex = 0
        ringPrimed = false
    }

    /// Free lookahead ring buffer memory. Call before deallocating the compressor.
    mutating func deallocate() {
        ringBuffer?.deallocate()
        ringBuffer = nil
        ringRMS?.deallocate()
        ringRMS = nil
        ringSlotSize = 0
        ringWriteIndex = 0
        ringPrimed = false
    }

    // MARK: - Static Compression Curve

    /// Compute gain reduction in dB for a given input level in dB.
    private func computeGainDb(inputDb: Float) -> Float {
        let threshold = targetLevelDb
        let R = ratio
        let W = kneeWidthDb

        if inputDb < (threshold - W / 2.0) {
            return 0.0
        } else if inputDb > (threshold + W / 2.0) {
            return (1.0 / R - 1.0) * (inputDb - threshold)
        } else {
            let x = inputDb - threshold + W / 2.0
            return (1.0 / R - 1.0) * x * x / (2.0 * W)
        }
    }

    // MARK: - Process Audio (In-Place, Block-Based with Lookahead)

    /// Process interleaved float audio in-place using block-based envelope tracking
    /// with a 2-block lookahead for predictive transient handling.
    @discardableResult
    mutating func process(
        buffer: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> (inputPeakDb: Float, outputPeakDb: Float) {
        let totalSamples = frameCount * channelCount
        guard totalSamples > 0, channelCount > 0 else {
            return (-100.0, -100.0)
        }

        // Lazy-init or re-init ring buffer if channel count changed
        let expectedSlotSize = blockSize * channelCount
        if ringBuffer == nil || ringSlotSize != expectedSlotSize {
            deallocate()
            initializeLookahead(channelCount: channelCount)
        }

        guard let ringBuf = ringBuffer, let ringRms = ringRMS else {
            return (-100.0, -100.0)
        }

        let dbToLinearScale: Float = 0.11512925  // ln(10) / 20

        var inputPeak: Float = 0.0
        var outputPeak: Float = 0.0
        var framesProcessed = 0

        while framesProcessed < frameCount {
            let framesRemaining = frameCount - framesProcessed
            let currentBlockSize = min(blockSize, framesRemaining)
            let blockSamples = currentBlockSize * channelCount
            let blockPtr = buffer.advanced(by: framesProcessed * channelCount)

            // --- 1. Compute block RMS using vDSP ---
            var sumSquares: Float = 0.0
            vDSP_dotpr(blockPtr, 1, blockPtr, 1, &sumSquares, vDSP_Length(blockSamples))
            let blockRms = sqrtf(sumSquares / Float(blockSamples))

            // Track input peak
            if blockRms > inputPeak { inputPeak = blockRms }

            // --- 2. Store incoming block in ring buffer ---
            let writeSlotPtr = ringBuf.advanced(by: ringWriteIndex * ringSlotSize)
            memcpy(writeSlotPtr, blockPtr, blockSamples * MemoryLayout<Float>.size)
            // Zero remaining slot space if current block is smaller than blockSize
            if blockSamples < ringSlotSize {
                memset(writeSlotPtr.advanced(by: blockSamples), 0,
                       (ringSlotSize - blockSamples) * MemoryLayout<Float>.size)
            }
            ringRms[ringWriteIndex] = blockRms

            // --- 3. Find max RMS across lookahead window (predictive envelope) ---
            var peekRms = blockRms
            for i in 0..<lookaheadBlocks {
                let rms = ringRms[i]
                if rms > peekRms { peekRms = rms }
            }

            // --- 4. Envelope tracking using lookahead-max RMS ---
            let envCoeff: Float = peekRms > envelopeLevel ? blockAttackCoeff : blockReleaseCoeff
            envelopeLevel = envCoeff * envelopeLevel + (1.0 - envCoeff) * peekRms

            // --- 5. Compute gain in dB ---
            let envelopeDb: Float = envelopeLevel > 1e-10 ? 20.0 * log10f(envelopeLevel) : -100.0
            let gainReductionDb = computeGainDb(inputDb: envelopeDb)

            // Smooth gain change
            let gainCoeff: Float = peekRms > envelopeLevel ? blockAttackCoeff : blockReleaseCoeff
            smoothedGainDb = gainCoeff * smoothedGainDb + (1.0 - gainCoeff) * gainReductionDb

            // Convert to linear gain (compression + makeup)
            let totalGainLinear = expf(smoothedGainDb * dbToLinearScale) * makeupLinear

            // --- 6. Output the delayed block from ring buffer ---
            if ringPrimed {
                // Read the oldest slot (the one about to be overwritten next)
                let readIndex = (ringWriteIndex + 1) % lookaheadBlocks
                let readSlotPtr = ringBuf.advanced(by: readIndex * ringSlotSize)
                memcpy(blockPtr, readSlotPtr, blockSamples * MemoryLayout<Float>.size)
            }
            // During priming: pass through the current block directly (no delay)
            // blockPtr already contains the incoming audio, so no copy needed.

            // --- 7. Apply gain to output block using vDSP ---
            var gain = totalGainLinear
            vDSP_vsmul(blockPtr, 1, &gain, blockPtr, 1, vDSP_Length(blockSamples))

            // --- 8. Soft clip overdriven samples ---
            var blockMax: Float = 0.0
            vDSP_maxmgv(blockPtr, 1, &blockMax, vDSP_Length(blockSamples))

            if blockMax > 1.0 {
                for j in 0..<blockSamples {
                    let s = blockPtr[j]
                    if s > 1.0 {
                        blockPtr[j] = 1.0 - expf(-s + 1.0)
                    } else if s < -1.0 {
                        blockPtr[j] = -(1.0 - expf(s + 1.0))
                    }
                }
                vDSP_maxmgv(blockPtr, 1, &blockMax, vDSP_Length(blockSamples))
            }

            if blockMax > outputPeak { outputPeak = blockMax }

            // Advance ring buffer write position
            ringWriteIndex = (ringWriteIndex + 1) % lookaheadBlocks
            if !ringPrimed && ringWriteIndex == 0 {
                ringPrimed = true
            }

            framesProcessed += currentBlockSize
        }

        // Convert peaks to dB for metering
        let inputPeakDb = inputPeak > 1e-10 ? 20.0 * log10f(inputPeak) : -100.0
        let outputPeakDb = outputPeak > 1e-10 ? 20.0 * log10f(outputPeak) : -100.0

        return (inputPeakDb, outputPeakDb)
    }

    /// Reset the compressor state (e.g. on stream discontinuity).
    mutating func reset() {
        envelopeLevel = 0.0
        smoothedGainDb = 0.0
        ringWriteIndex = 0
        ringPrimed = false
        if let buf = ringBuffer {
            memset(buf, 0, lookaheadBlocks * ringSlotSize * MemoryLayout<Float>.size)
        }
        if let rms = ringRMS {
            memset(rms, 0, lookaheadBlocks * MemoryLayout<Float>.size)
        }
    }
}
