import Foundation
import Testing

@testable import VellumMusicKit

/// Settings → About (#19): the version line, the server address it shows, and the credits and
/// licence texts that are obligations rather than decoration.
@Suite("Settings About")
struct SettingsAboutTests {
    @Test("version and build read as \"1.1 (4)\", degrading cleanly when either is missing")
    func versionString() {
        #expect(AppVersionInfo(infoDictionary: ["CFBundleShortVersionString": "1.1", "CFBundleVersion": "4"]).displayString == "1.1 (4)")
        #expect(AppVersionInfo(infoDictionary: ["CFBundleShortVersionString": "1.1"]).displayString == "1.1")
        #expect(AppVersionInfo(infoDictionary: ["CFBundleShortVersionString": "2.0", "CFBundleVersion": "2.0"]).displayString == "2.0")
        #expect(AppVersionInfo(infoDictionary: ["CFBundleVersion": "7"]).displayString == "Build 7")
        #expect(AppVersionInfo(infoDictionary: ["CFBundleShortVersionString": "  "]).displayString == "Unknown")
        #expect(AppVersionInfo(infoDictionary: nil).displayString == "Unknown")
    }

    @Test("the server address shows host and port only, never a path or query")
    func serverAddress() {
        #expect(AboutServerSummary.displayAddress("https://music.example.com") == "music.example.com")
        #expect(AboutServerSummary.displayAddress("http://192.168.1.10:4533/") == "192.168.1.10:4533")
        #expect(AboutServerSummary.displayAddress("https://proxy.example/navidrome?token=secret") == "proxy.example")
        #expect(AboutServerSummary.displayAddress("   ") == nil)
    }

    @Test("Radio Browser and MusicBrainz are credited with their sites")
    func attributionObligations() {
        let byId = Dictionary(uniqueKeysWithValues: AboutCredits.acknowledgements.map { ($0.id, $0) })
        #expect(byId["radio-browser"]?.url.host == "www.radio-browser.info")
        #expect(byId["musicbrainz"]?.url.host == "musicbrainz.org")
        #expect(byId["radio-browser"]?.detail.contains("Radio Browser") == true)
        #expect(byId["musicbrainz"]?.detail.contains("MusicBrainz") == true)
    }

    @Test("the MIT-licensed Beat This model carries its copyright and permission notice in full")
    func mitNoticeTravelsWithTheApp() {
        let beatThis = AboutCredits.licences.first { $0.id == "beat-this" }
        #expect(beatThis != nil)
        let text = beatThis?.text ?? ""
        #expect(text.contains("Copyright (c) 2024 Institute of Computational Perception, JKU Linz, Austria"))
        #expect(text.contains("The above copyright notice and this permission notice shall be included"))
        #expect(text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
        #expect(AboutCredits.licences.contains { $0.id == "vellum" && $0.subtitle.contains("PolyForm Noncommercial") })
    }
}
