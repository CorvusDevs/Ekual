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

    // MARK: - Process Audio (In-Place, Block-Based)

    /// Process interleaved float audio in-place using block-based envelope tracking.
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

        let dbToLinearScale: Float = 0.11512925  // ln(10) / 20

        var inputPeak: Float = 0.0
        var outputPeak: Float = 0.0
        var framesProcessed = 0

        while framesProcessed < frameCount {
            let framesRemaining = frameCount - framesProcessed
            let currentBlockSize = min(blockSize, framesRemaining)
            let blockSamples = currentBlockSize * channelCount
            let blockPtr = buffer.advanced(by: framesProcessed * channelCount)

            // --- 1. Compute block RMS using vDSP (sum of squares over all samples) ---
            var sumSquares: Float = 0.0
            vDSP_dotpr(blockPtr, 1, blockPtr, 1, &sumSquares, vDSP_Length(blockSamples))
            let blockRms = sqrtf(sumSquares / Float(blockSamples))

            // Track input peak
            if blockRms > inputPeak { inputPeak = blockRms }

            // --- 2. Envelope tracking (block-level) ---
            let envCoeff: Float = blockRms > envelopeLevel ? blockAttackCoeff : blockReleaseCoeff
            envelopeLevel = envCoeff * envelopeLevel + (1.0 - envCoeff) * blockRms

            // --- 3. Compute gain in dB ---
            let envelopeDb: Float = envelopeLevel > 1e-10 ? 20.0 * log10f(envelopeLevel) : -100.0
            let gainReductionDb = computeGainDb(inputDb: envelopeDb)

            // Smooth gain change
            let gainCoeff: Float = blockRms > envelopeLevel ? blockAttackCoeff : blockReleaseCoeff
            smoothedGainDb = gainCoeff * smoothedGainDb + (1.0 - gainCoeff) * gainReductionDb

            // Convert to linear gain (compression + makeup)
            let totalGainLinear = expf(smoothedGainDb * dbToLinearScale) * makeupLinear

            // --- 4. Apply gain to entire block using vDSP ---
            var gain = totalGainLinear
            vDSP_vsmul(blockPtr, 1, &gain, blockPtr, 1, vDSP_Length(blockSamples))

            // --- 5. Soft clip using vDSP clamping + tanh for overdriven samples ---
            // First, find if any samples exceed [-1, 1] to avoid unnecessary work
            var blockMax: Float = 0.0
            vDSP_maxmgv(blockPtr, 1, &blockMax, vDSP_Length(blockSamples))

            if blockMax > 1.0 {
                // Apply soft clipping only to samples that need it
                for j in 0..<blockSamples {
                    let s = blockPtr[j]
                    if s > 1.0 {
                        blockPtr[j] = 1.0 - expf(-s + 1.0)
                    } else if s < -1.0 {
                        blockPtr[j] = -(1.0 - expf(s + 1.0))
                    }
                }
                // Re-measure peak after clipping
                vDSP_maxmgv(blockPtr, 1, &blockMax, vDSP_Length(blockSamples))
            }

            if blockMax > outputPeak { outputPeak = blockMax }

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
    }
}
