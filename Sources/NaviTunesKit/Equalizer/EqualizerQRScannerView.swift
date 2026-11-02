import SwiftUI
#if canImport(VisionKit) && os(iOS)
import VisionKit

struct EqualizerQRScannerView: UIViewControllerRepresentable {
    var onScan: (EqualizerPresetExport) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if !uiViewController.isScanning {
            try? uiViewController.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (EqualizerPresetExport) -> Void
        let onCancel: () -> Void

        init(onScan: @escaping (EqualizerPresetExport) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            process(item, scanner: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard let item = addedItems.first else { return }
            process(item, scanner: dataScanner)
        }

        private func process(_ item: RecognizedItem, scanner: DataScannerViewController) {
            guard case .barcode(let barcode) = item,
                  let payload = barcode.payloadStringValue,
                  let data = Data(base64Encoded: payload),
                  let export = try? JSONDecoder().decode(EqualizerPresetExport.self, from: data)
            else { return }
            scanner.stopScanning()
            onScan(export)
        }
    }
}
#endif
