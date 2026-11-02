import AVFoundation
import Foundation

/// Produces `TransitionMetadata` for one local audio file, on the phone. The coordinator owns
/// scheduling (lazy, next-track-only, low priority); this is the per-file computation.
protocol TransitionAnalyzing: Sendable {
    /// Human-readable provenance written into `TransitionMetadata.analyzer`.
    var name: String { get }
    /// Whether this analyzer can run at all (for the Core ML one: the compiled model is in the
    /// bundle). When false the coordinator never schedules work and every pair is a gap.
    var isAvailable: Bool { get }
    func analyze(fileURL: URL, trackId: String) async throws -> TransitionMetadata
}

enum TransitionAnalysisError: Error, Equatable {
    case modelUnavailable
    case unreadableAudio
    case noBeatsFound
    case cancelled
}

/// Beat This small, running through Core ML on fixed 30 s chunks, plus the RMS intro/outro
/// heuristic and a BS.1770-style loudness pass. The preprocessing mirrors the reference
/// `LogMelSpect`: 22 050 Hz mono, 1024-point FFT, hop 441 (50 fps), 128 slaney mel bands from
/// 30 Hz to 11 kHz, magnitude (power 1), `log1p(1000·x)`.
///
/// The model is loaded lazily and released after each track, so the resident cost outside an
/// analysis is zero. One chunk is `1 × 1500 × 128` floats in and `2 × 1500` out: the activation
/// memory is bounded by the chunk, not the song.
final class CoreMLBeatAnalyzer: TransitionAnalyzing, @unchecked Sendable {
    let name = "beat_this:small0/coreml"
    static let modelResourceName = "BeatThisSmall"
    static let sampleRate: Double = 22_050
    static let hop = 441
    static let fps: Double = 50
    static let chunkFrames = 1500
    static let borderFrames = 6

    private let modelURL: URL?

    init(bundle: Bundle = .module) {
        modelURL = bundle.url(forResource: Self.modelResourceName, withExtension: "mlmodelc")
    }

    var isAvailable: Bool { modelURL != nil }

    func analyze(fileURL: URL, trackId: String) async throws -> TransitionMetadata {
        guard let modelURL else { throw TransitionAnalysisError.modelUnavailable }
        let decoded = try BeatThisFeatures.decodeMono(fileURL: fileURL, targetRate: Self.sampleRate)
        guard !decoded.samples.isEmpty else { throw TransitionAnalysisError.unreadableAudio }
        try Task.checkCancellation()
        let mel = BeatThisFeatures.logMel(samples: decoded.samples, sampleRate: Self.sampleRate)
        try Task.checkCancellation()
        let logits = try CoreMLChunkRunner(modelURL: modelURL).run(frames: mel, chunk: Self.chunkFrames, border: Self.borderFrames)
        let (beats, downbeats) = BeatThisFeatures.pickPeaks(beat: logits.beat, downbeat: logits.downbeat, fps: Self.fps)
        guard beats.count >= 2 else { throw TransitionAnalysisError.noBeatsFound }
        return BeatThisFeatures.assemble(
            trackId: trackId,
            samples: decoded.samples,
            sampleRate: Self.sampleRate,
            duration: decoded.duration,
            beats: beats,
            downbeats: downbeats,
            analyzer: name,
        )
    }
}

/// Everything around the model that is plain arithmetic, so it is testable on synthetic input.
enum BeatThisFeatures {
    struct Decoded {
        let samples: [Float]
        let duration: TimeInterval
    }

    /// Reads any AVFoundation-decodable file as mono float at `targetRate`.
    static func decodeMono(fileURL: URL, targetRate: Double) throws -> Decoded {
        guard let file = try? AVAudioFile(forReading: fileURL) else { throw TransitionAnalysisError.unreadableAudio }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else {
            throw TransitionAnalysisError.unreadableAudio
        }
        let inCapacity: AVAudioFrameCount = 32_768
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCapacity) else {
            throw TransitionAnalysisError.unreadableAudio
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(duration * targetRate) + 1024)
        var reachedEnd = false
        while !reachedEnd {
            let outCapacity = AVAudioFrameCount(Double(inCapacity) * targetRate / file.processingFormat.sampleRate) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { break }
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                do {
                    inBuffer.frameLength = 0
                    try file.read(into: inBuffer, frameCount: inCapacity)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error { throw TransitionAnalysisError.unreadableAudio }
            if let data = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || outBuffer.frameLength == 0 { reachedEnd = true }
        }
        return Decoded(samples: samples, duration: duration)
    }

    /// `[frame][128]` log-mel features. A straight DFT-by-definition implementation would be too
    /// slow for a 4-minute song; this uses `vDSP` through `MelSpectrogram`, kept in its own file so
    /// the Accelerate dependency sits in one place.
    static func logMel(samples: [Float], sampleRate: Double) -> [[Float]] {
        MelSpectrogram(sampleRate: sampleRate, fftSize: 1024, hop: 441, melBands: 128, fMin: 30, fMax: 11_000)
            .logMelFrames(samples, logMultiplier: 1000)
    }

    /// The reference "minimal" postprocessor: a local maximum within ±3 frames (70 ms) whose
    /// logit is above 0 (probability > 0.5), then adjacent peaks collapsed.
    static func pickPeaks(beat: [Float], downbeat: [Float], fps: Double) -> (beats: [TimeInterval], downbeats: [TimeInterval]) {
        func peaks(_ logits: [Float]) -> [TimeInterval] {
            var out: [TimeInterval] = []
            let n = logits.count
            var i = 0
            while i < n {
                let v = logits[i]
                if v > 0 {
                    let lo = max(0, i - 3), hi = min(n - 1, i + 3)
                    var isMax = true
                    for j in lo ... hi where logits[j] > v { isMax = false; break }
                    if isMax {
                        out.append(Double(i) / fps)
                        i += 3
                    }
                }
                i += 1
            }
            return out
        }
        let b = peaks(beat)
        // A downbeat must also be a beat: snap each downbeat peak to the nearest beat peak.
        let d = peaks(downbeat).compactMap { t -> TimeInterval? in
            guard let nearest = b.min(by: { abs($0 - t) < abs($1 - t) }), abs(nearest - t) <= 0.07 else { return nil }
            return nearest
        }
        return (b, Array(Set(d)).sorted())
    }

    /// Tempo, bars, sections (heuristic), loudness, cues — the same rules as `analyze.py`.
    static func assemble(
        trackId: String,
        samples: [Float],
        sampleRate: Double,
        duration: TimeInterval,
        beats: [TimeInterval],
        downbeats: [TimeInterval],
        analyzer: String,
    ) -> TransitionMetadata {
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.filter { $0 > 0 }
        let beatDuration = TransitionMetadata.median(intervals) ?? 0.5
        let tempo = beatDuration > 0 ? 60 / beatDuration : 0
        let dbIntervals = zip(downbeats.dropFirst(), downbeats).map { $0 - $1 }.filter { $0 > 0 }
        var beatsPerBar = 4
        if let m = TransitionMetadata.median(dbIntervals), beatDuration > 0 {
            let n = Int((m / beatDuration).rounded())
            if (2 ... 7).contains(n) { beatsPerBar = n }
        }
        let bar = beatDuration * Double(beatsPerBar)

        // Sections from per-bar RMS over downbeat edges.
        var edges = downbeats
        if edges.first.map({ $0 > 0.5 }) ?? true { edges.insert(0, at: 0) }
        if duration - (edges.last ?? 0) > 0.5 { edges.append(duration) }
        let barRMS: [Double] = zip(edges.dropLast(), edges.dropFirst()).map { s, e in
            let a = max(0, Int(s * sampleRate)), b = min(samples.count, Int(e * sampleRate))
            guard b > a else { return 0 }
            var acc: Double = 0
            for i in a ..< b { acc += Double(samples[i] * samples[i]) }
            return (acc / Double(b - a)).squareRoot()
        }
        let runs = IntroOutroHeuristic.analyze(barRMS: barRMS)
        let sections = IntroOutroHeuristic.sections(from: runs, edges: edges)

        let cues = cuePoints(beats: beats, downbeats: downbeats, sections: sections, duration: duration, bar: bar)
        let meter = LoudnessMeter(sampleRate: sampleRate)
        let loudness = TransitionMetadata.Loudness(
            integrated: meter.integratedLUFS(samples),
            range: meter.loudnessRangeLU(samples),
            intro: meter.integratedLUFS(samples, from: cues.mixIn, to: cues.mixIn + 10),
            outro: meter.integratedLUFS(samples, from: cues.mixOut - 10, to: cues.mixOut),
        )
        return TransitionMetadata(
            version: TransitionMetadata.supportedVersion,
            trackId: trackId,
            duration: duration,
            tempo: tempo,
            beats: beats,
            downbeats: downbeats,
            beatConfidence: beatConfidence(beats: beats, duration: duration),
            key: nil,
            loudness: loudness,
            sections: sections,
            cues: cues,
            analyzer: analyzer,
        )
    }

    /// 1.0 for a steady grid, 0 for rubato or no beats — `1 − 8·MAD(interval)/median`, scaled by
    /// how much of the track the grid covers. Same formula as the harness.
    static func beatConfidence(beats: [TimeInterval], duration: TimeInterval) -> Double {
        guard beats.count >= 8, duration > 0 else { return 0 }
        let iv = zip(beats.dropFirst(), beats).map { $0 - $1 }
        guard let med = TransitionMetadata.median(iv), med > 0 else { return 0 }
        let mad = (TransitionMetadata.median(iv.map { abs($0 - med) }) ?? 0) / med
        let coverage = min(1, (beats[beats.count - 1] - beats[0]) / max(1, duration - 2))
        return max(0, min(1, 1 - 8 * mad)) * coverage
    }

    /// Mix-in: the downbeat 8 bars before the intro ends, or the first downbeat. Mix-out: the
    /// outro's first downbeat, else 8 bars before the last downbeat. Same rules as the harness.
    static func cuePoints(
        beats: [TimeInterval],
        downbeats: [TimeInterval],
        sections: [TransitionMetadata.Section],
        duration: TimeInterval,
        bar: TimeInterval,
    ) -> TransitionMetadata.Cues {
        let intro = sections.first { $0.label == "intro" }
        let outro = sections.first { $0.label == "outro" }
        let firstDB = downbeats.first ?? 0
        let lastDB = downbeats.last ?? duration
        var mixIn = firstDB
        if let intro, !downbeats.isEmpty {
            let target = intro.end - 8 * bar
            if target > firstDB, let nearest = downbeats.min(by: { abs($0 - target) < abs($1 - target) }) {
                mixIn = nearest
            }
        }
        var mixOut: TimeInterval
        if let outro, let first = downbeats.first(where: { $0 >= outro.start - 0.01 }) {
            mixOut = first
        } else {
            mixOut = lastDB - 8 * bar
        }
        mixOut = max(mixIn + bar, min(mixOut, duration - 2 * bar))
        if let earlier = downbeats.last(where: { $0 <= mixOut + 0.01 }) { mixOut = earlier }
        return TransitionMetadata.Cues(mixIn: mixIn, mixOut: mixOut)
    }
}
