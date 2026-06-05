import SwiftUI

struct SettingsPlaybackView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showResetConfirm = false
    @AppStorage("streamingDiskCacheEnabled") private var streamingDiskCacheEnabled = false

    private var isDefault: Bool {
        app.wifiStreamBitRate == .none
            && app.cellularStreamBitRate == .kbps320
            && app.wifiStreamFormat == .raw
            && app.cellularStreamFormat == .raw
            && app.downloadQualityTier == .kbps320
            && app.downloadFormat == .mp3
            && !app.showSkipIntervalButtons
            && !app.showSleepTimerButton
            && app.skipBackwardInterval == .s15
            && app.skipForwardInterval == .s30
            && app.remoteControlMode == .skipTrack
            && app.defaultPlaybackRate == .normal
            && app.artistPlayMode == .topSongs
    }

    var body: some View {
        List {
            streamingSection
            downloadingSection
            streamCacheSection
            playerControlsSection
            skipIntervalsSection
            remoteControlsSection
            playbackSpeedSection
            if !isDefault {
                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        showResetConfirm = true
                    }
                }
            }
        }
        .navigationTitle("Sound & Playback")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset sound and playback settings?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                app.resetPlaybackSettingsToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var streamingSection: some View {
        Section {
            networkQualityHint
            Picker("Wi‑Fi max bitrate", selection: $app.wifiStreamBitRate) {
                ForEach(StreamBitRateOption.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .tint(MusicDesign.accent)
            Picker("Wi‑Fi format", selection: $app.wifiStreamFormat) {
                ForEach(app.availableStreamFormats) { format in
                    Text(format.title).tag(format)
                }
            }
            .tint(MusicDesign.accent)
            Picker("Cellular max bitrate", selection: $app.cellularStreamBitRate) {
                ForEach(StreamBitRateOption.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .tint(MusicDesign.accent)
            Picker("Cellular format", selection: $app.cellularStreamFormat) {
                ForEach(app.availableStreamFormats) { format in
                    Text(format.title).tag(format)
                }
            }
            .tint(MusicDesign.accent)
        } header: {
            Text("Streaming")
        } footer: {
            Text("Active tier follows the network (Wi‑Fi vs cellular). Some formats may not work on every server.")
        }
    }

    @ViewBuilder
    private var networkQualityHint: some View {
        if app.prefersCellularStreamingQuality {
            Label("Using cellular streaming settings", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Using Wi‑Fi streaming settings", systemImage: "wifi")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var downloadingSection: some View {
        Section {
            Picker("Max bitrate", selection: $app.downloadQualityTier) {
                ForEach(DownloadQualityTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .tint(MusicDesign.accent)
            Picker("Format", selection: $app.downloadFormat) {
                ForEach(DownloadFormatOption.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .tint(MusicDesign.accent)
        } header: {
            Text("Downloading")
        } footer: {
            Text("Download format is separate from streaming. Exotic formats may fail on some servers.")
        }
    }

    private var streamCacheSection: some View {
        Section {
            Toggle("Cache streamed songs", isOn: $streamingDiskCacheEnabled)
                .tint(MusicDesign.accent)
        } header: {
            Text("Stream Cache")
        } footer: {
            Text("Keeps a copy of songs you stream so replaying a recent track is instant, with no extra data use. Experimental — turn off if you notice playback issues.")
        }
    }

    private var playerControlsSection: some View {
        Section {
            Toggle("Show skip interval buttons", isOn: $app.showSkipIntervalButtons)
                .tint(MusicDesign.accent)
            Toggle("Show sleep timer button", isOn: $app.showSleepTimerButton)
                .tint(MusicDesign.accent)
            Picker("Artist play button", selection: $app.artistPlayMode) {
                ForEach(ArtistPlayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .tint(MusicDesign.accent)
        } header: {
            Text("Player Controls")
        } footer: {
            Text("Controls what the artist page play button starts. Long-press the button to pick a one-off mode.")
        }
    }

    private var skipIntervalsSection: some View {
        Section {
            Picker("Skip backward", selection: $app.skipBackwardInterval) {
                ForEach(SkipIntervalOption.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .tint(MusicDesign.accent)
            Picker("Skip forward", selection: $app.skipForwardInterval) {
                ForEach(SkipIntervalOption.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .tint(MusicDesign.accent)
        } header: {
            Text("Skip Intervals")
        }
    }

    private var remoteControlsSection: some View {
        Section {
            Picker("Lock screen controls", selection: $app.remoteControlMode) {
                ForEach(RemoteControlMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .tint(MusicDesign.accent)
        } header: {
            Text("Remote Controls")
        } footer: {
            Text("Skip track shows next/previous on the lock screen. Skip interval shows jump forward/back buttons with your configured seconds.")
        }
    }

    private var playbackSpeedSection: some View {
        Section {
            Picker("Default speed", selection: $app.defaultPlaybackRate) {
                ForEach(PlaybackRateOption.allCases) { rate in
                    Text(rate.title).tag(rate)
                }
            }
            .tint(MusicDesign.accent)
        } header: {
            Text("Playback Speed")
        } footer: {
            Text("You can also change speed from Now Playing while listening.")
        }
    }
}
