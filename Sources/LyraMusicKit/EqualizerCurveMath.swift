import CoreGraphics
import Foundation

/// Log-frequency curve math shared by the EQ graph, draw surface, and band resampling.
enum EqualizerCurveMath {
    static let minFrequency: Float = EqualizerBand.frequencies.first ?? 32
    static let maxFrequency: Float = EqualizerBand.frequencies.last ?? 16_000

    // MARK: - Coordinate mapping

    static func frequencyToNormalizedX(_ frequency: Float) -> CGFloat {
        let minLog = log10(Double(minFrequency))
        let maxLog = log10(Double(maxFrequency))
        let value = log10(Double(max(minFrequency, min(maxFrequency, frequency))))
        return CGFloat((value - minLog) / (maxLog - minLog))
    }

    static func normalizedXToFrequency(_ x: CGFloat) -> Float {
        let clamped = min(max(Double(x), 0), 1)
        let minLog = log10(Double(minFrequency))
        let maxLog = log10(Double(maxFrequency))
        let logValue = minLog + clamped * (maxLog - minLog)
        return Float(pow(10, logValue))
    }

    static func gainToNormalizedY(_ gain: Float) -> CGFloat {
        let range = EqualizerBand.gainRange
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        return CGFloat(1 - (gain - range.lowerBound) / span)
    }

    static func normalizedYToGain(_ y: CGFloat, precisionMode: Bool = false) -> Float {
        let range = EqualizerBand.gainRange
        let span = range.upperBound - range.lowerBound
        let clamped = min(max(Double(y), 0), 1)
        var gain = range.upperBound - Float(clamped) * span
        if precisionMode {
            gain = (gain * 2).rounded() / 2
        }
        return min(max(gain, range.lowerBound), range.upperBound)
    }

    static func point(forFrequency frequency: Float, gain: Float, in size: CGSize) -> CGPoint {
        CGPoint(
            x: frequencyToNormalizedX(frequency) * size.width,
            y: gainToNormalizedY(gain) * size.height,
        )
    }

    // MARK: - Interpolation

    /// Smooth curve samples for graph rendering.
    static func curveSamples(
        gains: [Float],
        sampleCount: Int = 64,
    ) -> [(frequency: Float, gain: Float)] {
        let normalized = EqualizerPreset.normalizedGains(gains)
        guard sampleCount > 1 else {
            return EqualizerBand.frequencies.enumerated().map { index, frequency in
                (frequency, normalized[index])
            }
        }
        return (0 ..< sampleCount).map { index in
            let t = Float(index) / Float(sampleCount - 1)
            let frequency = interpolatedFrequency(t: t)
            let gain = interpolatedGain(at: frequency, bandGains: normalized)
            return (frequency, gain)
        }
    }

    static func interpolatedGain(at frequency: Float, bandGains: [Float]) -> Float {
        let freqs = EqualizerBand.frequencies
        let gains = EqualizerPreset.normalizedGains(bandGains)
        if let first = freqs.first, frequency <= first { return gains[0] }
        if let last = freqs.last, frequency >= last { return gains[gains.count - 1] }

        for index in 0 ..< (freqs.count - 1) {
            let low = freqs[index]
            let high = freqs[index + 1]
            if frequency >= low, frequency <= high {
                let logLow = log10(Double(low))
                let logHigh = log10(Double(high))
                let logF = log10(Double(frequency))
                let t = (logF - logLow) / (logHigh - logLow)
                let g0 = Double(gains[index])
                let g1 = Double(gains[index + 1])
                return Float(g0 + (g1 - g0) * t)
            }
        }
        return 0
    }

    private static func interpolatedFrequency(t: Float) -> Float {
        let minLog = log10(Double(minFrequency))
        let maxLog = log10(Double(maxFrequency))
        let logValue = minLog + Double(t) * (maxLog - minLog)
        return Float(pow(10, logValue))
    }

    // MARK: - Draw path → bands

    /// Resample a drawn stroke into the fixed 10-band gain vector.
    static func gainsFromDrawSamples(
        _ samples: [(x: CGFloat, y: CGFloat)],
        precisionMode: Bool = false,
    ) -> [Float] {
        guard !samples.isEmpty else { return EqualizerBand.flatGains }
        return EqualizerBand.frequencies.map { frequency in
            let targetX = frequencyToNormalizedX(frequency)
            let nearest = samples.min(by: {
                abs($0.x - targetX) < abs($1.x - targetX)
            })
            let y = nearest?.y ?? 0.5
            return normalizedYToGain(y, precisionMode: precisionMode)
        }
    }

    /// Moving-average smooth of raw touch samples before band quantization.
    static func smoothDrawSamples(_ samples: [(x: CGFloat, y: CGFloat)], window: Int = 3) -> [(x: CGFloat, y: CGFloat)] {
        guard samples.count > 2, window > 1 else { return samples }
        return samples.enumerated().map { index, sample in
            let start = max(0, index - window / 2)
            let end = min(samples.count - 1, index + window / 2)
            let slice = samples[start ... end]
            let avgY = slice.map(\.y).reduce(0, +) / CGFloat(slice.count)
            return (sample.x, avgY)
        }
    }
}
