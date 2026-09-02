import Foundation

#if os(iOS)
import CoreLocation
import NetworkExtension
import SystemConfiguration.CaptiveNetwork
#endif

/// Outcome of trying to read the current Wi‑Fi SSID (for home-network setup).
enum HomeWifiSSIDReadResult: Equatable {
    case ssid(String)
    case locationDenied
    case locationRestricted
    /// User allowed location but declined temporary precise location (required on iOS 14+).
    case preciseLocationRequired
    /// Location is granted but iOS still won't expose the SSID (not on Wi‑Fi, etc.).
    case wifiInfoUnavailable
    case unavailable
}

/// Detects private-LAN server URLs and whether the device is on the user's home Wi‑Fi.
///
/// iOS only exposes the current SSID when location permission is granted **and** the app
/// holds the Access WiFi Information entitlement (`com.apple.developer.networking.wifi-info`).
/// The SSID read must happen **while** Core Location updates are active, and iOS 14+ requires
/// precise (full) location authorization for the read.
enum HomePresenceHelper {
    /// True when `url` points at a private LAN host (e.g. `192.168.1.198:4533`).
    static func isLocalNetworkServerURL(_ url: URL?) -> Bool {
        isPrivateLANHost(url?.host)
    }

    static func isPrivateLANHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty
        else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("10.") { return true }
        if host.hasPrefix("169.254.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    /// Requests When-In-Use location if needed so the SSID APIs can run.
    static func ensureLocationAccessForHomeDetection() async {
        #if os(iOS)
        await HomeLocationAuthorizer.shared.ensureWhenInUseAuthorization()
        #endif
    }

    /// Reads the current Wi‑Fi network name for "Use current Wi‑Fi" / home detection.
    static func fetchCurrentHomeSSID() async -> HomeWifiSSIDReadResult {
        #if os(iOS)
        #if targetEnvironment(simulator)
        return .unavailable
        #else
        return await HomeLocationAuthorizer.shared.readCurrentHomeSSID()
        #endif
        #else
        return .unavailable
        #endif
    }

    /// True when the device is on Wi‑Fi and its SSID matches a configured home network.
    static func isAtHome(homeSSIDs: [String]) async -> Bool {
        guard !homeSSIDs.isEmpty else { return false }
        if case .ssid(let current) = await fetchCurrentHomeSSID() {
            return homeSSIDs.contains(current)
        }
        return false
    }
}

#if os(iOS)
@MainActor
private final class HomeLocationAuthorizer: NSObject, CLLocationManagerDelegate {
    static let shared = HomeLocationAuthorizer()

    private let manager = CLLocationManager()
    private var authWaiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var locationReadyWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeLocationSessions = 0
    private var receivedLocationFix = false

    private override init() {
        super.init()
        manager.delegate = self
    }

    func readCurrentHomeSSID() async -> HomeWifiSSIDReadResult {
        let status = await ensureWhenInUseAuthorization()
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .denied:
            return .locationDenied
        case .restricted:
            return .locationRestricted
        case .notDetermined:
            return .unavailable
        @unknown default:
            return .unavailable
        }

        guard await ensurePreciseLocationForSSIDRead() else {
            return .preciseLocationRequired
        }

        return await withActiveLocationSession {
            if let ssid = await readCurrentSSIDFromSystem(), !ssid.isEmpty {
                return .ssid(ssid)
            }
            return .wifiInfoUnavailable
        }
    }

    @discardableResult
    func ensureWhenInUseAuthorization() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                authWaiters.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        default:
            return status
        }
    }

    /// iOS 14+ requires precise location (not reduced accuracy) for SSID reads.
    private func ensurePreciseLocationForSSIDRead() async -> Bool {
        if manager.accuracyAuthorization == .fullAccuracy { return true }
        return await withCheckedContinuation { continuation in
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "HomeWifiDetection") { _ in
                Task { @MainActor in
                    continuation.resume(returning: self.manager.accuracyAuthorization == .fullAccuracy)
                }
            }
        }
    }

    /// Keeps Core Location updating through `operation`. SSID APIs return nil if called after updates stop.
    private func withActiveLocationSession<T>(_ operation: () async -> T) async -> T {
        let startedHere = activeLocationSessions == 0
        activeLocationSessions += 1
        if startedHere {
            receivedLocationFix = false
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.startUpdatingLocation()
            await waitForLocationReady(timeout: .milliseconds(1500))
        }
        defer {
            activeLocationSessions -= 1
            if activeLocationSessions == 0 {
                manager.stopUpdatingLocation()
            }
        }
        return await operation()
    }

    private func waitForLocationReady(timeout: Duration) async {
        if receivedLocationFix { return }
        await withCheckedContinuation { continuation in
            locationReadyWaiters.append(continuation)
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                let waiters = locationReadyWaiters
                locationReadyWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
    }

    /// Tries CaptiveNetwork first (often succeeds when NEHotspotNetwork logs nehelper errors), then NEHotspotNetwork.
    private func readCurrentSSIDFromSystem() async -> String? {
        if let ssid = fetchCaptiveNetworkSSID(), !ssid.isEmpty { return ssid }
        return await fetchNEHotspotSSID()
    }

    private func fetchCaptiveNetworkSSID() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for interface in interfaces {
            guard let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [String: AnyObject],
                  let ssid = info[kCNNetworkInfoKeySSID as String] as? String,
                  !ssid.isEmpty
            else { continue }
            return ssid
        }
        return nil
    }

    private func fetchNEHotspotSSID() async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    NEHotspotNetwork.fetchCurrent { network in
                        continuation.resume(returning: network?.ssid)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            guard status != .notDetermined else { return }
            let waiters = authWaiters
            authWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: status)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            receivedLocationFix = true
            let waiters = locationReadyWaiters
            locationReadyWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let waiters = locationReadyWaiters
            locationReadyWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}
#endif
