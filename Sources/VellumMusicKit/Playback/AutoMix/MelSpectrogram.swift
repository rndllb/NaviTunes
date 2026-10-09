import Accelerate
import Foundation

/// Log-mel front end matching torchaudio's `MelSpectrogram(n_fft=1024, hop=441, f_min=30,
/// f_max=11000, n_mels=128, mel_scale="slaney", normalized="frame_length", power=1)` followed by
/// `log1p(1000·x)`, as Beat This was trained on. Hann window, centre-padded (reflect) frames.
struct MelSpectrogram {
    let sampleRate: Double
    let fftSize: Int
    let hop: Int
    let melBands: Int
    let fMin: Double
    let fMax: Double

    private let window: [Float]
    private let filterbank: [Float]   // melBands × (fftSize/2 + 1), row-major
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let log2n: vDSP_Length

    init(sampleRate: Double, fftSize: Int, hop: Int, melBands: Int, fMin: Double, fMax: Double) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hop = hop
        self.melBands = melBands
        self.fMin = fMin
        self.fMax = fMax
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        // torchaudio `normalized="frame_length"` divides the spectrum by sqrt(sum(window²))·…; with
        // power=1 that is a per-frame scale of 1/sqrt(frame_length). Fold it into the window.
        let scale = 1 / Float(fftSize).squareRoot()
        window = w.map { $0 * scale }
        filterbank = Self.slaneyFilterbank(sampleRate: sampleRate, fftSize: fftSize, melBands: melBands, fMin: fMin, fMax: fMax)
        log2n = vDSP_Length(log2(Double(fftSize)))
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
    }

    /// `[frame][melBands]`, one frame per `hop` samples, centred like torchaudio (`center=True`).
    func logMelFrames(_ samples: [Float], logMultiplier: Float) -> [[Float]] {
        let half = fftSize / 2
        let bins = half + 1
        // Reflect-pad by fftSize/2 on both sides.
        var padded = [Float](repeating: 0, count: samples.count + fftSize)
        for i in 0 ..< samples.count { padded[half + i] = samples[i] }
        for i in 0 ..< half {
            padded[half - 1 - i] = samples[min(samples.count - 1, i + 1)]
            padded[half + samples.count + i] = samples[max(0, samples.count - 2 - i)]
        }
        let frameCount = 1 + samples.count / hop
        var frames: [[Float]] = []
        frames.reserveCapacity(frameCount)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: fftSize)
        var magnitude = [Float](repeating: 0, count: bins)
        var mel = [Float](repeating: 0, count: melBands)
        for f in 0 ..< frameCount {
            let start = f * hop
            vDSP_vmul(Array(padded[start ..< start + fftSize]), 1, window, 1, &frame, 1, vDSP_Length(fftSize))
            frame.withUnsafeBufferPointer { fp in
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                        // In-place transform: a second descriptor over the same buffers keeps the
                        // call free of overlapping inout access on `split`.
                        let input = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        fft.forward(input: input, output: &split)
                        // Packed real FFT: DC in real[0], Nyquist in imag[0]; scale by 1/2.
                        var mags = [Float](repeating: 0, count: half)
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                        for i in 1 ..< half { magnitude[i] = mags[i] * 0.5 }
                        magnitude[0] = abs(rp[0]) * 0.5
                        magnitude[half] = abs(ip[0]) * 0.5
                    }
                }
            }
            // mel = filterbank · magnitude
            vDSP_mmul(filterbank, 1, magnitude, 1, &mel, 1, vDSP_Length(melBands), 1, vDSP_Length(bins))
            frames.append(mel.map { log1p(logMultiplier * $0) })
        }
        return frames
    }

    /// Slaney-style triangular mel filterbank (librosa / torchaudio `mel_scale="slaney"`, no norm).
    static func slaneyFilterbank(sampleRate: Double, fftSize: Int, melBands: Int, fMin: Double, fMax: Double) -> [Float] {
        let bins = fftSize / 2 + 1
        func hzToMel(_ f: Double) -> Double {
            let fSp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fSp, logstep = log(6.4) / 27
            return f >= minLogHz ? minLogMel + log(f / minLogHz) / logstep : f / fSp
        }
        func melToHz(_ m: Double) -> Double {
            let fSp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fSp, logstep = log(6.4) / 27
            return m >= minLogMel ? minLogHz * exp(logstep * (m - minLogMel)) : fSp * m
        }
        let mMin = hzToMel(fMin), mMax = hzToMel(fMax)
        let melPoints = (0 ..< melBands + 2).map { melToHz(mMin + (mMax - mMin) * Double($0) / Double(melBands + 1)) }
        let fftFreqs = (0 ..< bins).map { Double($0) * sampleRate / Double(fftSize) }
        var fb = [Float](repeating: 0, count: melBands * bins)
        for m in 0 ..< melBands {
            let lower = melPoints[m], centre = melPoints[m + 1], upper = melPoints[m + 2]
            for k in 0 ..< bins {
                let f = fftFreqs[k]
                let up = (f - lower) / max(1e-9, centre - lower)
                let down = (upper - f) / max(1e-9, upper - centre)
                fb[m * bins + k] = Float(max(0, min(up, down)))
            }
        }
        return fb
    }
}

/// ITU-R BS.1770 loudness on a mono float signal: K-weighting (shelf + high-pass biquads at the
/// 48 kHz reference coefficients re-derived for the actual rate), 400 ms blocks at 75 % overlap,
/// absolute gate −70 LUFS and relative gate −10 LU.
struct LoudnessMeter {
    let sampleRate: Double

    func integratedLUFS(_ x: [Float], from: TimeInterval? = nil, to: TimeInterval? = nil) -> Double {
        let a = max(0, Int((from ?? 0) * sampleRate))
        let b = min(x.count, Int((to ?? Double(x.count) / sampleRate) * sampleRate))
        guard b - a > Int(sampleRate * 0.4) else { return -70 }
        let blocks = blockLoudness(Array(x[a ..< b]))
        return gatedMean(blocks)
    }

    /// EBU R128 loudness range (LRA) approximation on 3 s short-term blocks.
    func loudnessRangeLU(_ x: [Float]) -> Double {
        let win = Int(3 * sampleRate), hop = Int(sampleRate)
        guard x.count > win else { return 0 }
        var values: [Double] = []
        var s = 0
        while s + win <= x.count {
            let v = gatedMean(blockLoudness(Array(x[s ..< s + win])))
            if v > -70 { values.append(v) }
            s += hop
        }
        guard values.count >= 3 else { return 0 }
        let top = values.max()!
        let kept = values.filter { $0 > top - 20 }.sorted()
        func pct(_ p: Double) -> Double { kept[min(kept.count - 1, Int(p * Double(kept.count - 1)))] }
        return pct(0.95) - pct(0.10)
    }

    private func gatedMean(_ blocks: [Double]) -> Double {
        let abs = blocks.filter { $0 > -70 }
        guard !abs.isEmpty else { return -70 }
        let first = meanPower(abs)
        let rel = abs.filter { $0 > first - 10 }
        guard !rel.isEmpty else { return -70 }
        return meanPower(rel)
    }

    private func meanPower(_ lufs: [Double]) -> Double {
        let p = lufs.map { pow(10, ($0 + 0.691) / 10) }.reduce(0, +) / Double(lufs.count)
        return -0.691 + 10 * log10(max(1e-12, p))
    }

    /// Momentary (400 ms) block loudness values after K-weighting.
    private func blockLoudness(_ x: [Float]) -> [Double] {
        let y = KWeighting(sampleRate: sampleRate).apply(x)
        let block = Int(0.4 * sampleRate), step = Int(0.1 * sampleRate)
        guard y.count >= block else { return [] }
        var out: [Double] = []
        var s = 0
        while s + block <= y.count {
            var acc: Double = 0
            for i in s ..< s + block { acc += Double(y[i] * y[i]) }
            let ms = acc / Double(block)
            out.append(-0.691 + 10 * log10(max(1e-12, ms)))
            s += step
        }
        return out
    }
}

/// The two BS.1770 biquads, designed for the given sample rate (the spec gives 48 kHz
/// coefficients; these are the standard bilinear re-derivations used by pyloudnorm).
struct KWeighting {
    let sampleRate: Double

    func apply(_ x: [Float]) -> [Float] {
        let fs = sampleRate
        // Stage 1: high shelf (+4 dB above ~1.5 kHz).
        let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / fs), vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        let shelf = Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0,
        )
        // Stage 2: high-pass at 38 Hz.
        let f1 = 38.13547087602444, q1 = 0.5003270373238773
        let k1 = tan(Double.pi * f1 / fs)
        let a01 = 1 + k1 / q1 + k1 * k1
        let hp = Biquad(
            b0: 1 / a01, b1: -2 / a01, b2: 1 / a01,
            a1: 2 * (k1 * k1 - 1) / a01,
            a2: (1 - k1 / q1 + k1 * k1) / a01,
        )
        return hp.run(shelf.run(x))
    }
}

struct Biquad {
    let b0, b1, b2, a1, a2: Double

    func run(_ x: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0 ..< x.count {
            let xi = Double(x[i])
            let yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = xi; y2 = y1; y1 = yi
            y[i] = Float(yi)
        }
        return y
    }
}
