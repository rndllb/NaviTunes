import SwiftUI
import UniformTypeIdentifiers

struct SettingsEqualizerView: View {
    @EnvironmentObject private var app: AppModel
    @State private var drawGains: [Float] = EqualizerBand.flatGains
    /// Whether the draw surface is on screen. See ``drawSection``.
    @State private var isEditingCurve = false
    @State private var exportName = "My EQ"
    @State private var showImporter = false
    @State private var showHearingTest = false
    @State private var showQRShare = false
    @State private var showQRScanner = false

    var body: some View {
        List {
            enableSection

            if app.equalizerEnabled {
                graphSection
                drawSection
                automationSection
                advancedSection
                sharingSection
                bandsSection
            }
        }
        .navigationTitle("Equalizer")
        .settingsSubpageChrome()
        .toolbar {
            if app.equalizerEnabled {
                ToolbarItemGroup(placement: MusicToolbar.trailingItemPlacement) {
                    Button {
                        app.undoEqualizerChange()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!app.equalizerHistory.canUndo)
                    .accessibilityLabel("Undo")

                    Button {
                        app.redoEqualizerChange()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!app.equalizerHistory.canRedo)
                    .accessibilityLabel("Redo")
                }
            }
        }
        .onAppear {
            if !EqualizerPreset.catalog.contains(where: { $0.id == app.equalizerPresetId }) {
                app.equalizerPresetId = EqualizerPreset.catalog[0].id
            }
            drawGains = app.equalizerBandGains
            app.reloadEqualizerProfiles()
        }
        .onChange(of: app.equalizerBandGains) { _, newValue in
            drawGains = newValue
        }
        .sheet(isPresented: $showHearingTest) {
            NavigationStack {
                EqualizerHearingTestView()
                    .environmentObject(app)
            }
        }
        .sheet(isPresented: $showQRShare) {
            NavigationStack {
                EqualizerQRShareView(export: app.exportEqualizerPreset(named: exportName))
                    .environmentObject(app)
            }
        }
        #if canImport(VisionKit) && os(iOS)
        .fullScreenCover(isPresented: $showQRScanner) {
            EqualizerQRScannerView(
                onScan: { export in
                    app.importEqualizerPreset(export)
                    showQRScanner = false
                },
                onCancel: { showQRScanner = false },
            )
            .ignoresSafeArea()
        }
        #endif
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: EqualizerPresetExport.fileExtension) ?? .json],
            allowsMultipleSelection: false,
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importPreset(from: url)
        }
    }

    private var enableSection: some View {
        Section {
            Toggle("Enable equalizer", isOn: $app.equalizerEnabled)
                .tint(MusicDesign.accent)
            if app.equalizerEnabled {
                Toggle("Bypass", isOn: $app.equalizerBypass)
                    .tint(MusicDesign.accent)
            }
        } footer: {
            Text("EQ applies to downloads and cached streams. Enabling EQ turns on stream caching — new streams play immediately and switch to EQ once cached. Internet radio always bypasses EQ.")
        }
    }

    private var graphSection: some View {
        Section {
            EqualizerCurveGraphView(
                gains: app.effectiveEqualizerBandGains(for: app.player.activeTrack),
                comparisonGains: showsLayeredCurve ? app.equalizerBandGains : nil,
            )
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            if showsLayeredCurve {
                Text("Solid curve is what playback uses (includes vintage, enhancements, and hearing profile). Dashed line is your base band setting.")
                    .font(.caption)
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }
        } header: {
            Text("Response")
        } footer: {
            if app.equalizerHistory.canUndo {
                Text("Use the toolbar buttons to undo or redo curve edits. \(app.equalizerHistory.undoStepCount) edit\(app.equalizerHistory.undoStepCount == 1 ? "" : "s") can be undone.")
            } else {
                Text("Use Bypass to A/B against your curve. EQ only affects downloaded tracks and cached streams — live streams and radio use normal playback until cached.")
            }
        }
    }

    private var showsLayeredCurve: Bool {
        app.equalizerVintageMode != .off
            || app.equalizerBassEnhancement
            || app.equalizerVocalEnhancement
            || app.equalizerLoudnessCompensation
            || app.equalizerStereoWidth != .normal
            || app.equalizerHeadphoneProfileId != nil
            || app.equalizerAdaptiveEnabled
            || app.equalizerFrequencyToolMode != .off
            || app.equalizerHearingOffset.contains(where: { abs($0) > 0.01 })
    }

    /// Preset, precision toggle, and the draw surface behind an explicit edit mode.
    ///
    /// The surface used to sit in the list permanently, and a draw gesture is indistinguishable
    /// from the start of a scroll until it has already moved — so scrolling past it redrew the
    /// curve and silently dropped the active preset to Flat (`onEditingEnded` reassigns
    /// `equalizerPresetId`). Losing a preset to a scroll is not recoverable by scrolling back.
    ///
    /// Behind a button, the gesture only exists while the user has said they want to draw.
    private var drawSection: some View {
        Section {
            Picker("Preset", selection: $app.equalizerPresetId) {
                ForEach(EqualizerPreset.catalog) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .pickerStyle(.navigationLink)
            .onChange(of: app.equalizerPresetId) { _, newValue in
                app.applyEqualizerPreset(EqualizerPreset.preset(id: newValue))
            }

            Toggle("Precision draw (0.5 dB snap)", isOn: $app.equalizerPrecisionDraw)
                .tint(MusicDesign.accent)

            Button {
                // Re-seed from the live gains on entry so the surface always opens showing what
                // is actually applied, not whatever was left from the last edit.
                if !isEditingCurve { drawGains = app.equalizerBandGains }
                withAnimation(.snappy) { isEditingCurve.toggle() }
            } label: {
                Label(
                    isEditingCurve ? "Done Editing" : "Edit Curve",
                    systemImage: isEditingCurve ? "checkmark" : "pencil.and.outline",
                )
            }

            if isEditingCurve {
                EqualizerDrawSurface(
                    gains: $drawGains,
                    precisionMode: app.equalizerPrecisionDraw,
                    onEditingBegan: {
                        app.beginEqualizerEditSession()
                    },
                    onEditingEnded: {
                        app.setEqualizerBandGains(drawGains, recordHistory: false)
                        app.endEqualizerEditSession()
                        app.equalizerPresetId = EqualizerPreset.catalog[0].id
                    },
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        } header: {
            Text("Draw EQ")
        } footer: {
            if !isEditingCurve {
                Text("The Response graph above shows the curve in use. Editing here replaces the selected preset.")
            }
        }
    }

    private var automationSection: some View {
        Section {
            Button("Save for current artist") { app.saveEqualizerProfileForCurrentArtist() }
                .disabled(app.player.activeTrack == nil)
            Button("Save for current album") { app.saveEqualizerProfileForCurrentAlbum() }
                .disabled(app.player.activeTrack == nil)
            Button("Save for current output device") { app.saveEqualizerProfileForCurrentDevice() }
            if let route = EqualizerDeviceRoute.currentRouteDisplayName() {
                Text("Output: \(route)")
                    .font(.caption)
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }

            if app.equalizerProfiles.isEmpty {
                Text("No saved profiles yet")
                    .foregroundStyle(MusicDesign.secondaryLabel)
            } else {
                ForEach(app.equalizerProfiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                            Text(profile.kind.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            app.removeEqualizerProfile(id: profile.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("Saved artist and album curves apply when those tracks play. Device curves blend with your base setting for the current output.")
        }
    }

    private var advancedSection: some View {
        Group {
            Section {
                Toggle("Bass enhancement", isOn: $app.equalizerBassEnhancement)
                    .tint(MusicDesign.accent)
                Toggle("Vocal enhancement", isOn: $app.equalizerVocalEnhancement)
                    .tint(MusicDesign.accent)
                Toggle("Loudness compensation", isOn: $app.equalizerLoudnessCompensation)
                    .tint(MusicDesign.accent)
                Picker("Stereo width", selection: $app.equalizerStereoWidth) {
                    ForEach(EqualizerStereoWidth.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Vintage mode", selection: $app.equalizerVintageMode) {
                    ForEach(EqualizerVintageMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Headphone compensation", selection: Binding(
                    get: { app.equalizerHeadphoneProfileId ?? "off" },
                    set: { app.equalizerHeadphoneProfileId = $0 == "off" ? nil : $0 },
                )) {
                    Text("Off").tag("off")
                    ForEach(HeadphoneCompensationCatalog.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
            } header: {
                Text("Enhancement")
            } footer: {
                Text("Vintage and enhancement layers stack on your base curve and apply during EQ playback. Use a downloaded song to hear changes immediately.")
            }

            Section {
                Picker("Frequency tool", selection: $app.equalizerFrequencyToolMode) {
                    ForEach(EqualizerFrequencyToolMode.allCases) { mode in
                        Text(mode == .off ? "Off" : mode == .solo ? "Solo band" : "Mute band").tag(mode)
                    }
                }
                if app.equalizerFrequencyToolMode != .off {
                    Picker("Target band", selection: $app.equalizerFrequencyToolBand) {
                        ForEach(0 ..< EqualizerBand.count, id: \.self) { index in
                            Text(bandLabel(index)).tag(index)
                        }
                    }
                }
                Toggle("Adaptive Smart EQ", isOn: $app.equalizerAdaptiveEnabled)
                    .tint(MusicDesign.accent)
                if app.equalizerAdaptiveEnabled {
                    Picker("Adaptive strength", selection: $app.equalizerAdaptiveStrength) {
                        ForEach(EqualizerAdaptiveStrength.allCases) { strength in
                            Text(strength.title).tag(strength)
                        }
                    }
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Solo and mute reshape playback by cutting other bands. Adaptive EQ uses track metadata heuristics.")
            }

            Section {
                Button("Hearing test") { showHearingTest = true }
                if let track = app.player.activeTrack {
                    Button("Suggest EQ for \(track.title)") {
                        app.applyEqualizerSuggestionForCurrentTrack()
                    }
                }
            } header: {
                Text("Calibration")
            } footer: {
                Text("Genre suggest picks the closest preset for the current track's genre tags. Nothing changes if the track has no recognised genre.")
            }
        }
    }

    private var sharingSection: some View {
        Group {
            Section {
                HStack {
                    Text("Name")
                    Spacer()
                    TextField("My EQ", text: $exportName)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.primary)
                }
                if let data = exportPresetData {
                    ShareLink(
                        item: data,
                        preview: SharePreview(exportName, image: Image(systemName: "slider.vertical.3")),
                    ) {
                        Label("Export file", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import file", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Preset File")
            } footer: {
                Text("Save or load a .vellumeq curve file.")
            }

            Section {
                Button {
                    showQRShare = true
                } label: {
                    Label("Show QR code", systemImage: "qrcode")
                }
                #if canImport(VisionKit) && os(iOS)
                Button {
                    showQRScanner = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                }
                #endif
            } header: {
                Text("QR Code")
            } footer: {
                Text("Transfer a curve to another device running Vellum.")
            }
        }
    }

    private var exportPresetData: Data? {
        try? JSONEncoder().encode(app.exportEqualizerPreset(named: exportName))
    }

    private var bandsSection: some View {
        Section {
            ForEach(0 ..< EqualizerBand.count, id: \.self) { index in
                equalizerBandRow(index: index)
            }
        } header: {
            Text("Bands")
        } footer: {
            Text("Gains are in dB (−12 to +12). Changes apply live during playback.")
        }
    }

    private func equalizerBandRow(index: Int) -> some View {
        let gainBinding = Binding<Float>(
            get: {
                let gains = app.equalizerBandGains
                guard index < gains.count else { return 0 }
                return gains[index]
            },
            set: { app.setEqualizerBandGain(index: index, gain: $0) },
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(bandLabel(index))
                Spacer()
                Text(gainLabel(gainBinding.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: gainBinding, in: EqualizerBand.gainRange, step: 0.5)
                .tint(MusicDesign.accent)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in app.beginEqualizerEditSession() }
                        .onEnded { _ in app.endEqualizerEditSession() },
                )
        }
        .padding(.vertical, 2)
    }

    private func bandLabel(_ index: Int) -> String {
        let frequency = Int(EqualizerBand.frequencies[index])
        return frequency >= 1_000 ? String(format: "%.0f kHz", Double(frequency) / 1_000) : "\(frequency) Hz"
    }

    private func gainLabel(_ gain: Float) -> String {
        if gain > 0 { return String(format: "+%.1f dB", gain) }
        return String(format: "%.1f dB", gain)
    }

    private func importPreset(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let export = try? JSONDecoder().decode(EqualizerPresetExport.self, from: data)
        else { return }
        app.importEqualizerPreset(export)
    }
}
