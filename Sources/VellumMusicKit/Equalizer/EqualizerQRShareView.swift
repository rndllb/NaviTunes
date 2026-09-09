import CoreImage.CIFilterBuiltins
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// QR export/import for EQ presets (local sharing without a marketplace backend).
struct EqualizerQRShareView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let export: EqualizerPresetExport
    @State private var qrImage: Image?

    var body: some View {
        List {
            Section {
                if let qrImage {
                    qrImage
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                Text("Scan with Vellum to import “\(export.name)”.")
                    .font(.footnote)
                    .foregroundStyle(MusicDesign.secondaryLabel)
            } header: {
                Text("QR Code")
            }

            if let data = try? JSONEncoder().encode(export) {
                ShareLink(
                    item: data,
                    preview: SharePreview(export.name, image: Image(systemName: "qrcode")),
                ) {
                    Label("Share file", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Share EQ")
        .musicNavigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { await generateQR() }
    }

    @MainActor
    private func generateQR() async {
        guard let data = try? JSONEncoder().encode(export) else { return }
        let payload = data.base64EncodedString()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }
        #if canImport(UIKit)
        qrImage = Image(uiImage: UIImage(cgImage: cgImage))
        #endif
    }
}
