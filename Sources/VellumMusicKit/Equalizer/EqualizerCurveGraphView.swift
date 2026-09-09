import SwiftUI

/// Live frequency-response curve for the 10-band EQ.
struct EqualizerCurveGraphView: View {
    var gains: [Float]
    var comparisonGains: [Float]? = nil
    var height: CGFloat = 140

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { context, canvasSize in
                drawGrid(context: &context, size: canvasSize)
                if let comparisonGains {
                    drawCurve(
                        context: &context,
                        size: canvasSize,
                        gains: comparisonGains,
                        stroke: comparisonStroke,
                        fill: nil,
                        dashed: true,
                    )
                }
                drawCurve(
                    context: &context,
                    size: canvasSize,
                    gains: gains,
                    stroke: primaryStroke,
                    fill: primaryFill,
                    dashed: false,
                )
                drawBandMarkers(context: &context, size: canvasSize, gains: gains)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MusicDesign.tertiarySurfaceFill)
        )
    }

    private var primaryStroke: Color {
        MusicDesign.accent
    }

    private var primaryFill: Color {
        MusicDesign.accent.opacity(colorScheme == .dark ? 0.22 : 0.14)
    }

    private var comparisonStroke: Color {
        Color.secondary.opacity(0.8)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let zeroY = EqualizerCurveMath.gainToNormalizedY(0) * size.height
        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: 0, y: zeroY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
        context.stroke(
            zeroLine,
            with: .color(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4]),
        )

        for frequency in EqualizerBand.frequencies {
            let x = EqualizerCurveMath.frequencyToNormalizedX(frequency) * size.width
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                line,
                with: .color(Color.primary.opacity(0.06)),
                lineWidth: 1,
            )
        }
    }

    private func drawCurve(
        context: inout GraphicsContext,
        size: CGSize,
        gains: [Float],
        stroke: Color,
        fill: Color?,
        dashed: Bool = false,
    ) {
        let samples = EqualizerCurveMath.curveSamples(gains: gains)
        guard let first = samples.first else { return }

        var line = Path()
        let start = EqualizerCurveMath.point(forFrequency: first.frequency, gain: first.gain, in: size)
        line.move(to: CGPoint(x: start.x, y: size.height))
        line.addLine(to: start)
        for sample in samples.dropFirst() {
            let point = EqualizerCurveMath.point(forFrequency: sample.frequency, gain: sample.gain, in: size)
            line.addLine(to: point)
        }
        if let last = samples.last {
            let end = EqualizerCurveMath.point(forFrequency: last.frequency, gain: last.gain, in: size)
            line.addLine(to: CGPoint(x: end.x, y: size.height))
        }
        line.closeSubpath()

        if let fill {
            context.fill(line, with: .color(fill))
        }

        var strokePath = Path()
        strokePath.move(to: start)
        for sample in samples.dropFirst() {
            let point = EqualizerCurveMath.point(forFrequency: sample.frequency, gain: sample.gain, in: size)
            strokePath.addLine(to: point)
        }
        context.stroke(
            strokePath,
            with: .color(stroke),
            style: StrokeStyle(lineWidth: dashed ? 1.5 : 2.5, dash: dashed ? [5, 4] : []),
        )
    }

    private func drawBandMarkers(context: inout GraphicsContext, size: CGSize, gains: [Float]) {
        let normalized = EqualizerPreset.normalizedGains(gains)
        for index in EqualizerBand.frequencies.indices {
            let frequency = EqualizerBand.frequencies[index]
            let gain = normalized[index]
            let center = EqualizerCurveMath.point(forFrequency: frequency, gain: gain, in: size)
            let rect = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(MusicDesign.accent),
            )
        }
    }
}
