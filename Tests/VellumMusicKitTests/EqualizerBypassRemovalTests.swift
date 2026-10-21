import Foundation
import Testing

@testable import VellumMusicKit

/// #14: the Bypass toggle is gone; "Enable equalizer" is the only switch. Someone who had Bypass
/// on was hearing no EQ, so after the update they must still hear none (the EQ comes up off),
/// not suddenly get their curve back. The old setting is then deleted.
@Suite("Equalizer without Bypass (#14)")
struct EqualizerBypassRemovalTests {
    static func defaults(enabled: Bool?, bypass: Bool?) -> UserDefaults {
        let suite = "t788-eq-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        if let enabled { d.set(enabled, forKey: EqualizerStorage.enabledKey) }
        if let bypass { d.set(bypass, forKey: "vellumEqualizerBypass") }
        return d
    }

    @Test("EQ on with Bypass on: comes up off, and the Bypass setting is gone")
    func bypassedEqualizerStaysSilent() {
        let d = Self.defaults(enabled: true, bypass: true)
        #expect(EqualizerStorage.loadEnabledMigratingBypass(d) == false)
        #expect(d.bool(forKey: EqualizerStorage.enabledKey) == false)
        #expect(d.object(forKey: "vellumEqualizerBypass") == nil)
    }

    @Test("EQ on with Bypass off: stays on, and the Bypass setting is gone")
    func activeEqualizerStaysOn() {
        let d = Self.defaults(enabled: true, bypass: false)
        #expect(EqualizerStorage.loadEnabledMigratingBypass(d) == true)
        #expect(d.object(forKey: "vellumEqualizerBypass") == nil)
    }

    @Test("EQ off: stays off whatever Bypass said")
    func offStaysOff() {
        #expect(EqualizerStorage.loadEnabledMigratingBypass(Self.defaults(enabled: false, bypass: true)) == false)
        #expect(EqualizerStorage.loadEnabledMigratingBypass(Self.defaults(enabled: nil, bypass: nil)) == false)
    }
}
