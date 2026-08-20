#if canImport(UIKit)
import SwiftUI
import UIKit

/// Square pan + pinch-zoom cropper built from stock SwiftUI primitives. Lets the
/// user frame an image inside a square viewport and returns JPEG data of exactly
/// what's visible. Used to crop a playlist cover before upload (covers are square).
struct SquareImageCropView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onCrop: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Committed zoom (≥ 1 so the image always fills the square) and pan.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Live gesture deltas, folded into the committed values on end.
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero
    /// The on-screen square side, captured so export can match the framing exactly.
    @State private var displaySide: CGFloat = 0
    /// The image after any 90° rotations. Rotation re-bakes the pixels (rather than
    /// applying a transform) so every bit of framing math below stays orientation-agnostic.
    @State private var rotatedImage: UIImage?

    private var currentImage: UIImage { rotatedImage ?? image }

    private let maxScale: CGFloat = 6
    private let exportSide: CGFloat = 1024

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let side = max(0, min(geo.size.width, geo.size.height) - 40)
                ZStack {
                    Color.black.ignoresSafeArea()
                    imageLayer(side: side)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                        }
                        .gesture(dragGesture(side: side).simultaneously(with: magnifyGesture(side: side)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear { displaySide = side }
                        .onChange(of: side) { _, newValue in displaySide = newValue }
                }
            }
            .navigationTitle("Move and Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") {
                        export()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button {
                        rotateClockwise()
                    } label: {
                        Label("Rotate", systemImage: "rotate.right")
                    }
                    .accessibilityHint("Rotates the image 90 degrees clockwise")
                    Spacer()
                }
            }
        }
    }

    /// Re-bakes the current image rotated 90° clockwise and resets the framing, since
    /// the previous zoom/pan no longer maps onto the rotated pixels.
    private func rotateClockwise() {
        let source = currentImage
        let newSize = CGSize(width: source.size.height, height: source.size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = source.scale
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let rotated = renderer.image { ctx in
            ctx.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            ctx.cgContext.rotate(by: .pi / 2)
            source.draw(in: CGRect(x: -source.size.width / 2, y: -source.size.height / 2,
                                   width: source.size.width, height: source.size.height))
        }
        rotatedImage = rotated
        scale = 1
        offset = .zero
    }

    private func imageLayer(side: CGFloat) -> some View {
        Image(uiImage: currentImage)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .scaleEffect(max(1, scale * pinch))
            .offset(resolvedOffset(side: side))
    }

    // MARK: Framing math

    /// Size the image occupies when `scaledToFill` into a `side × side` box at
    /// zoom 1 — one axis equals `side`, the other overflows by the aspect ratio.
    private func displayedBaseSize(side: CGFloat) -> CGSize {
        let image = currentImage
        let aspect = image.size.height == 0 ? 1 : image.size.width / image.size.height
        if aspect >= 1 { return CGSize(width: side * aspect, height: side) }
        return CGSize(width: side, height: side / aspect)
    }

    /// Clamp the requested offset so the square is always fully covered (no gaps).
    private func clampedOffset(_ raw: CGSize, side: CGFloat, scale effective: CGFloat) -> CGSize {
        let base = displayedBaseSize(side: side)
        let maxX = max(0, (base.width * effective - side) / 2)
        let maxY = max(0, (base.height * effective - side) / 2)
        return CGSize(
            width: min(max(raw.width, -maxX), maxX),
            height: min(max(raw.height, -maxY), maxY),
        )
    }

    private func resolvedOffset(side: CGFloat) -> CGSize {
        let raw = CGSize(width: offset.width + dragTranslation.width, height: offset.height + dragTranslation.height)
        return clampedOffset(raw, side: side, scale: max(1, scale * pinch))
    }

    // MARK: Gestures

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in
                let raw = CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height)
                offset = clampedOffset(raw, side: side, scale: max(1, scale))
            }
    }

    private func magnifyGesture(side: CGFloat) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                scale = min(max(scale * value.magnification, 1), maxScale)
                offset = clampedOffset(offset, side: side, scale: scale)
            }
    }

    // MARK: Export

    @MainActor
    private func export() {
        let side = displaySide
        let fallback = currentImage
        guard side > 0 else {
            onCrop(fallback.jpegData(compressionQuality: 0.9) ?? Data())
            return
        }
        let content = imageLayer(side: side)
            .frame(width: side, height: side)
            .clipped()
        let renderer = ImageRenderer(content: content)
        renderer.scale = max(1, exportSide / side)
        if let rendered = renderer.uiImage, let data = rendered.jpegData(compressionQuality: 0.9) {
            onCrop(data)
        } else {
            onCrop(fallback.jpegData(compressionQuality: 0.9) ?? Data())
        }
    }
}
#endif
