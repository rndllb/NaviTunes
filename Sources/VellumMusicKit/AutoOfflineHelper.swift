#if os(iOS)
import NetworkExtension

enum AutoOfflineHelper {
    static func fetchCurrentSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
}
#else
enum AutoOfflineHelper {
    static func fetchCurrentSSID() async -> String? { nil }
}
#endif
