import CoreML
import Foundation

/// Runs a compiled Beat This model over a whole song in fixed-size chunks, the way the reference
/// inference does (`split_piece` / `aggregate_prediction`): chunks of `chunk` frames overlapping
/// by `border` frames, with `border` frames discarded from each prediction's edges and the last
/// chunk shifted left so no short tail is run.
///
/// The model is loaded on `init` and released with the runner — one song's worth of life. The
/// Core ML input is a static `1 × chunk × 128` array, so the Neural Engine plan is compiled once
/// and the working set is one chunk regardless of song length.
struct CoreMLChunkRunner {
    struct Logits {
        let beat: [Float]
        let downbeat: [Float]
    }

    let model: MLModel

    init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    /// Pure chunk bookkeeping, mirrored from the reference, so it is testable without a model.
    /// Returns `(start, left padding, right padding)` for each chunk over `frameCount` frames.
    static func chunkPlan(frameCount: Int, chunk: Int, border: Int) -> [(start: Int, padLeft: Int, padRight: Int)] {
        guard frameCount > 0 else { return [] }
        if frameCount <= chunk - 2 * border {
            // Shorter than one chunk: a single, shorter run padded on both sides.
            return [(-border, border, max(0, border))]
        }
        var starts = Array(stride(from: -border, to: frameCount - border, by: chunk - 2 * border))
        starts[starts.count - 1] = frameCount - (chunk - border)
        return starts.map { start in
            (start, max(0, -start), max(0, min(border, start + chunk - frameCount)))
        }
    }

    func run(frames: [[Float]], chunk: Int, border: Int) throws -> Logits {
        let n = frames.count
        let bands = frames.first?.count ?? 128
        var beat = [Float](repeating: -1000, count: n)
        var downbeat = [Float](repeating: -1000, count: n)
        let input = try MLMultiArray(shape: [1, NSNumber(value: chunk), NSNumber(value: bands)], dataType: .float32)
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: chunk * bands)
        for plan in Self.chunkPlan(frameCount: n, chunk: chunk, border: border) {
            try Task.checkCancellation()
            // Fill: padding rows are zero, as the reference pads the spectrogram with zeros.
            for row in 0 ..< chunk {
                let src = plan.start + row
                let base = row * bands
                if src >= 0, src < n {
                    for b in 0 ..< bands { ptr[base + b] = frames[src][b] }
                } else {
                    for b in 0 ..< bands { ptr[base + b] = 0 }
                }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["spectrogram": input])
            let out = try model.prediction(from: provider)
            guard let b = out.featureValue(for: "beat")?.multiArrayValue,
                  let d = out.featureValue(for: "downbeat")?.multiArrayValue else { continue }
            // Keep the interior; the reference discards `border` frames at both ends.
            for row in border ..< (chunk - border) {
                let dst = plan.start + row
                guard dst >= 0, dst < n else { continue }
                beat[dst] = b[row].floatValue
                downbeat[dst] = d[row].floatValue
            }
        }
        return Logits(beat: beat, downbeat: downbeat)
    }
}
