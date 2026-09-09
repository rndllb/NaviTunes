#if os(iOS)
import NetworkExtension

enum AutoOfflineHelper {
    static func fetchCurrentSSID() async -> String? {
        if case .ssid(let ssid) = await HomePresenceHelper.fetchCurrentHomeSSID() {
            return ssid
        }
        return nil
    }
}
#else
enum AutoOfflineHelper {
    static func fetchCurrentSSID() async -> String? { nil }
}
#endif
