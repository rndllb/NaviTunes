import SwiftUI

/// Touch-drawn EQ curve; resamples strokes into the 10 fixed bands.
struct EqualizerDrawSurface: View {
    @Binding var gains: [Float]
    var precisionMode: Bool
    var onEditingBegan: () -> Void = {}
    var onEditingEnded: () -> Void

    @State private var strokeSamples: [(x: CGFloat, y: CGFloat)] = []
    @State private var isDrawing = false

    private let height: CGFloat = 180

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MusicDesign.tertiarySurfaceFill)
                    Canvas { context, canvasSize in
                        drawGuides(context: &context, size: canvasSize)
                        if !strokeSamples.isEmpty {
                            drawStroke(context: &context, size: canvasSize, samples: strokeSamples)
                        }
                        drawCurve(context: &context, size: canvasSize, gains: gains)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isDrawing {
                                    onEditingBegan()
                                }
                                isDrawing = true
                                let x = min(max(value.location.x / size.width, 0), 1)
                                let y = min(max(value.location.y / size.height, 0), 1)
                                strokeSamples.append((x, y))
                                if strokeSamples.count > 120 {
                                    strokeSamples.removeFirst(strokeSamples.count - 120)
                                }
                                applyStroke(size: size)
                            }
                            .onEnded { _ in
                                isDrawing = false
                                strokeSamples.removeAll()
                                onEditingEnded()
                            },
                    )
                }
            }
            .frame(height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1),
            )

            Text(isDrawing ? "Drawing…" : "Drag to shape the curve")
                .font(.caption)
                .foregroundStyle(MusicDesign.secondaryLabel)
        }
    }

    private func applyStroke(size: CGSize) {
        let sorted = strokeSamples.sorted { $0.x < $1.x }
        let smoothed = EqualizerCurveMath.smoothDrawSamples(sorted)
        gains = EqualizerCurveMath.gainsFromDrawSamples(smoothed, precisionMode: precisionMode)
    }

    private func drawGuides(context: inout GraphicsContext, size: CGSize) {
        let zeroY = EqualizerCurveMath.gainToNormalizedY(0) * size.height
        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: 0, y: zeroY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
        context.stroke(
            zeroLine,
            with: .color(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.1)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4]),
        )
    }

    private func drawStroke(
        context: inout GraphicsContext,
        size: CGSize,
        samples: [(x: CGFloat, y: CGFloat)],
    ) {
        guard let first = samples.first else { return }
        var path = Path()
        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
        for sample in samples.dropFirst() {
            path.addLine(to: CGPoint(x: sample.x * size.width, y: sample.y * size.height))
        }
        context.stroke(
            path,
            with: .color(MusicDesign.accent.opacity(0.55)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round),
        )
    }

    private func drawCurve(context: inout GraphicsContext, size: CGSize, gains: [Float]) {
        let samples = EqualizerCurveMath.curveSamples(gains: gains, sampleCount: 48)
        guard let first = samples.first else { return }
        var path = Path()
        let start = EqualizerCurveMath.point(forFrequency: first.frequency, gain: first.gain, in: size)
        path.move(to: start)
        for sample in samples.dropFirst() {
            path.addLine(to: EqualizerCurveMath.point(forFrequency: sample.frequency, gain: sample.gain, in: size))
        }
        context.stroke(path, with: .color(MusicDesign.accent), lineWidth: 2)
    }
}
