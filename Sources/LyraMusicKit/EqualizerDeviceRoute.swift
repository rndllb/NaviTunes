import Foundation
#if os(iOS)
import AVFoundation
#endif

enum EqualizerDeviceRoute {
    static func currentRouteKey() -> String? {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let output = outputs.first else { return nil }
        return "\(output.portType.rawValue)|\(output.uid)"
        #else
        return nil
        #endif
    }

    static func currentRouteDisplayName() -> String? {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let output = outputs.first else { return nil }
        let name = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? output.portType.rawValue : name
        #else
        return nil
        #endif
    }

    static func seedPresetId(forRouteName name: String) -> String? {
        let lower = name.lowercased()
        if lower.contains("airpods") { return "airpods-pro" }
        if lower.contains("car") || lower.contains("vehicle") { return "car-audio" }
        if lower.contains("headphone") || lower.contains("beats") { return "wired-headphones" }
        if lower.contains("usb") || lower.contains("dac") { return "external-dac" }
        return nil
    }
}
