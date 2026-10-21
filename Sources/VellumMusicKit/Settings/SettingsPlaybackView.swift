import SwiftUI

struct SettingsPlaybackView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showResetConfirm = false
    // Matches the registered default in `AppModel.init`. `register(defaults:)` already makes the
    // stored value true, so this only matters if the two ever disagree — which is exactly the
    // bug worth not having.
    @AppStorage("streamingDiskCacheEnabled") private var streamingDiskCacheEnabled = true

    private var isDefault: Bool {
        app.wifiStreamBitRate == .none
            && app.cellularStreamBitRate == .kbps320
            && app.wifiStreamFormat == .raw
            && app.cellularStreamFormat == .raw
            && app.downloadQualityTier == .kbps320
            && app.downloadFormat == .mp3
            && !app.showSkipIntervalButtons
            && !app.showSleepTimerButton
            && !app.autoMixEnabled
            && app.skipBackwardInterval == .s15
            && app.skipForwardInterval == .s30
            && app.remoteControlMode == .skipTrack
            && app.defaultPlaybackRate == .normal
            && app.artistPlayMode == .topSongs
    }

    var body: some View {
        List {
            equalizerSection
            autoMixSection
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
        .settingsSubpageChrome()
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
            Toggle("No streaming over cellular", isOn: $app.noStreamingOverCellular)
                .tint(MusicDesign.accent)
            // The cellular quality pickers describe streams that can no longer happen.
            if !app.noStreamingOverCellular {
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
            }
        } header: {
            Text("Streaming")
        } footer: {
            if app.noStreamingOverCellular {
                Text("On cellular, only downloaded songs and songs already cached on this iPhone play; others are skipped. Streaming quality follows the Wi‑Fi settings. Some formats may not work on every server.")
            } else {
                Text("Active tier follows the network (Wi‑Fi vs cellular). Some formats may not work on every server.")
            }
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
            // The old copy read "Required for the equalizer to apply on first play — enabling the
            // EQ turns this on automatically", which described the cache as though it existed to
            // serve the EQ. It is a streaming feature in its own right: it saves re-downloading a
            // track you replay. The EQ relationship runs the other way — the EQ needs a local
            // file, so it depends on this — and stating it as a condition of the cache made the
            // setting read as EQ-only and easy to leave off.
            Text("Replays fully cached streams from disk instead of downloading them again. The equalizer needs a cached file to apply on first play, so turning the EQ on enables this too.")
        }
    }

    private var equalizerSection: some View {
        Section {
            NavigationLink {
                SettingsEqualizerView()
                    .environmentObject(app)
            } label: {
                HStack {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                    Spacer()
                    Text(app.equalizerEnabled ? EqualizerPreset.preset(id: app.equalizerPresetId).name : "Off")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var autoMixSection: some View {
        Section {
            Toggle("AutoMix", isOn: $app.autoMixEnabled)
                .tint(MusicDesign.accent)
            if app.autoMixEnabled, !app.player.autoMixAnalysisAvailable {
                Label("Needs the analysis model — transitions stay as they are until it is in this build.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if app.autoMixEnabled {
                AutoMixDiagnosticRow(player: app.player)
            }
        } header: {
            Text("AutoMix")
        } footer: {
            Text("Blends each song into the next like a DJ: beat-matched when the tempos fit, a smooth crossfade when they don't. Works on downloaded and streamed songs: the next song is fetched and analysed on this device while the current one plays, once, and the result is kept.")
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


/// One line of AutoMix status, live. Observes the engine directly so it updates on every decision
/// without a whole-`AppModel` publish.
private struct AutoMixDiagnosticRow: View {
    @ObservedObject var player: PlaybackEngine

    var body: some View {
        Text(player.autoMixDiagnostic)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
