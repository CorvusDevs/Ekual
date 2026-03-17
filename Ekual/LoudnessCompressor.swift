import Foundation
import Accelerate

// Real-time safe loudness compressor that mimics Windows Loudness Equalization.
// All methods are designed for use on the audio real-time thread:
// no allocations, no locks, no ObjC dispatch.

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
    var makeupGainDb: Float = 12.0

    // MARK: - Internal State

    /// Current smoothed envelope level in linear amplitude.
    private var envelopeLevel: Float = 0.0

    /// Current smoothed gain in dB (used for attack/release smoothing).
    private var smoothedGainDb: Float = 0.0

    /// Sample rate used for coefficient calculation.
    private var sampleRate: Float = 44100.0

    /// Pre-computed attack coefficient.
    private var attackCoeff: Float = 0.0

    /// Pre-computed release coefficient.
    private var releaseCoeff: Float = 0.0

    // MARK: - Initialization

    init(sampleRate: Float = 44100.0) {
        self.sampleRate = sampleRate
        updateCoefficients()
    }

    // MARK: - Coefficient Calculation

    private mutating func updateCoefficients() {
        // Time constant: coeff = exp(-1 / (time * sampleRate))
        // Using a block size of 1 sample for sample-by-sample processing.
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
    }

    mutating func setSampleRate(_ rate: Float) {
        sampleRate = rate
        updateCoefficients()
    }

    // MARK: - Static Compression Curve

    /// Compute gain reduction in dB for a given input level in dB,
    /// using threshold (targetLevelDb), ratio, and soft knee.
    private func computeGainDb(inputDb: Float) -> Float {
        let threshold = targetLevelDb
        let R = ratio
        let W = kneeWidthDb

        if inputDb < (threshold - W / 2.0) {
            // Below knee: no compression, but apply makeup
            return 0.0
        } else if inputDb > (threshold + W / 2.0) {
            // Above knee: full compression
            // output = threshold + (input - threshold) / R
            // gain = output - input = (1/R - 1) * (input - threshold)
            return (1.0 / R - 1.0) * (inputDb - threshold)
        } else {
            // In the knee region: quadratic interpolation
            let x = inputDb - threshold + W / 2.0
            return (1.0 / R - 1.0) * x * x / (2.0 * W)
        }
    }

    // MARK: - Process Audio (In-Place)

    /// Process interleaved float audio in-place.
    /// - Parameters:
    ///   - buffer: Pointer to interleaved float samples
    ///   - frameCount: Number of frames
    ///   - channelCount: Number of channels (interleaved)
    /// - Returns: Tuple of (peak input level dB, peak output level dB) for metering
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

        let makeupLinear = powf(10.0, makeupGainDb / 20.0)
        var inputPeak: Float = 0.0
        var outputPeak: Float = 0.0

        for i in 0..<frameCount {
            // Compute the RMS-like level across channels for this frame
            var sumSquares: Float = 0.0
            let base = i * channelCount
            for ch in 0..<channelCount {
                let sample = buffer[base + ch]
                sumSquares += sample * sample
            }
            let rmsLevel = sqrtf(sumSquares / Float(channelCount))

            // Track input peak
            if rmsLevel > inputPeak { inputPeak = rmsLevel }

            // Smooth the envelope with fast attack / slow release
            let coeff: Float
            if rmsLevel > envelopeLevel {
                coeff = attackCoeff
            } else {
                coeff = releaseCoeff
            }
            envelopeLevel = coeff * envelopeLevel + (1.0 - coeff) * rmsLevel

            // Convert envelope to dB
            let envelopeDb: Float
            if envelopeLevel > 1e-10 {
                envelopeDb = 20.0 * log10f(envelopeLevel)
            } else {
                envelopeDb = -100.0
            }

            // Compute desired gain reduction
            let gainReductionDb = computeGainDb(inputDb: envelopeDb)

            // Smooth the gain change (additional smoothing for stability)
            let gainCoeff: Float = rmsLevel > envelopeLevel ? attackCoeff : releaseCoeff
            smoothedGainDb = gainCoeff * smoothedGainDb + (1.0 - gainCoeff) * gainReductionDb

            // Convert gain to linear and include makeup gain
            let totalGainLinear = powf(10.0, smoothedGainDb / 20.0) * makeupLinear

            // Apply gain to all channels of this frame
            for ch in 0..<channelCount {
                let idx = base + ch
                buffer[idx] *= totalGainLinear

                // Soft clip to prevent harsh distortion
                let s = buffer[idx]
                if s > 1.0 {
                    buffer[idx] = 1.0 - expf(-s + 1.0)
                } else if s < -1.0 {
                    buffer[idx] = -(1.0 - expf(s + 1.0))
                }

                let absSample = fabsf(buffer[idx])
                if absSample > outputPeak { outputPeak = absSample }
            }
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
