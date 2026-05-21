import SwiftUI
import simd

/// Deterministic mesh artwork for Navidrome internet radio (no cover art from server).
enum RadioStationMeshArtwork {
    static func seedKey(for station: InternetRadioStation) -> String {
        seedKey(stationId: station.id)
    }

    static func seedKey(stationId: String) -> String {
        "internet-radio-\(stationId)"
    }

    static func seedKey(for track: Track) -> String? {
        track.isInternetRadioStream ? track.id : nil
    }
}

// MARK: - View

struct RadioStationMeshArtworkView: View {
    let seedKey: String
    var cornerRadius: CGFloat = 14

    private var spec: MeshSpec {
        MeshSpec(seedKey: seedKey)
    }

    var body: some View {
        MeshGradient(
            width: spec.width,
            height: spec.height,
            points: spec.points,
            colors: spec.colors,
            smoothsColors: true,
        )
        .aspectRatio(1, contentMode: .fill)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Mesh generation

private struct MeshSpec {
    let width: Int
    let height: Int
    let points: [SIMD2<Float>]
    let colors: [Color]

    /// Curated base hues so each station starts in a strong, balanced family.
    private static let anchorHues: [Double] = [
        0.56, 0.61, 0.67, 0.73, 0.78, 0.84, 0.91, 0.97,
        0.03, 0.07, 0.11, 0.16, 0.21, 0.28, 0.34, 0.41, 0.47, 0.52,
    ]

    init(seedKey: String) {
        var rng = SeededRNG(state: Self.fnv1a64(seedKey))
        let grid = 3 + Int(rng.next() % 2)
        width = grid
        height = grid
        let count = grid * grid
        let style = Int(rng.next() % 9)
        let baseHue = Self.anchorHues[Int(rng.next() % UInt64(Self.anchorHues.count))]
        let satBoost = rng.unit(0.55, 1.0)
        let briBoost = rng.unit(0.42, 0.92)

        var pts: [SIMD2<Float>] = []
        pts.reserveCapacity(count)
        for row in 0..<grid {
            for col in 0..<grid {
                let x = grid == 1 ? 0.5 : Float(col) / Float(grid - 1)
                let y = grid == 1 ? 0.5 : Float(row) / Float(grid - 1)
                pts.append(SIMD2<Float>(x, y))
            }
        }
        points = pts

        colors = (0..<count).map { index in
            Self.color(
                index: index,
                count: count,
                style: style,
                baseHue: baseHue,
                satBoost: satBoost,
                briBoost: briBoost,
                rng: &rng,
            )
        }
    }

    /// Original mesh variety (sat/brightness patterns) — hues stay analogous to ``baseHue`` only.
    private static func color(
        index: Int,
        count: Int,
        style: Int,
        baseHue: Double,
        satBoost: Double,
        briBoost: Double,
        rng: inout SeededRNG,
    ) -> Color {
        let t = count > 1 ? Double(index) / Double(count - 1) : 0
        var sat = satBoost
        var bri = briBoost
        var hue = baseHue

        switch style {
        case 0:
            hue = harmoniousHue(baseHue, offset: t * 0.08, jitter: rng.unit(-0.025, 0.025))
            sat = min(1, sat * 1.05 + 0.12)
            bri = min(0.98, bri + rng.unit(-0.08, 0.12))
        case 1:
            hue = harmoniousHue(baseHue, offset: 0.04 + t * 0.05, jitter: 0)
            sat = min(1, 0.75 + rng.unit(0, 0.25))
            bri = min(0.95, 0.5 + t * 0.4)
        case 2:
            hue = harmoniousHue(baseHue, offset: t * 0.06, jitter: 0)
            sat = min(1, 0.35 + rng.unit(0, 0.35))
            bri = min(0.96, 0.72 + rng.unit(-0.1, 0.15))
        case 3:
            hue = harmoniousHue(baseHue, offset: 0, jitter: rng.unit(-0.04, 0.04))
            sat = min(1, 0.88 + rng.unit(0, 0.12))
            bri = max(0.22, min(0.55, bri * 0.65 + rng.unit(-0.05, 0.08)))
        case 4:
            hue = harmoniousHue(baseHue, offset: 0.03 + t * 0.06, jitter: rng.unit(-0.02, 0.02))
            sat = min(1, 0.92 + rng.unit(-0.05, 0.08))
            bri = min(1, 0.58 + t * 0.38)
        case 5:
            let alt = index.isMultiple(of: 2) ? 0.045 : -0.025
            hue = harmoniousHue(baseHue, offset: t * 0.05 + alt, jitter: 0)
            sat = min(1, 0.62 + rng.unit(0.1, 0.38))
            bri = min(0.94, 0.48 + Double(index % 3) * 0.14)
        case 6:
            hue = harmoniousHue(baseHue, offset: Double(index % 5) * 0.018, jitter: 0)
            sat = min(1, 0.48 + rng.unit(0, 0.5))
            bri = min(0.9, 0.38 + t * 0.5)
        case 7:
            hue = harmoniousHue(baseHue, offset: 0, jitter: rng.unit(-0.05, 0.05))
            sat = min(1, 1.0)
            bri = min(1, 0.45 + rng.unit(0, 0.5))
        default:
            hue = harmoniousHue(baseHue, offset: t * 0.07, jitter: rng.unit(-0.03, 0.03))
            sat = min(1, sat + 0.2)
            bri = min(1, bri + rng.unit(-0.12, 0.18))
        }

        return Color(
            hue: hue,
            saturation: max(0.28, min(1, sat)),
            brightness: max(0.2, min(1, bri)),
        )
    }

    /// Keeps all mesh corners in the same color family (no complements / random opposing hues).
    private static func harmoniousHue(_ baseHue: Double, offset: Double, jitter: Double) -> Double {
        let drift = min(0.10, max(-0.10, offset + jitter))
        return wrapHue(baseHue + drift)
    }

    private static func wrapHue(_ hue: Double) -> Double {
        var h = hue.truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return h
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

private struct SeededRNG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_847_093_103 &+ 1_446_525_040_605_029_569
        return state
    }

    mutating func unit(_ min: Double, _ max: Double) -> Double {
        let u = Double(next() % 10_000) / 10_000.0
        return min + (max - min) * u
    }
}
