import SwiftUI

struct SettingsEqualizerView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        List {
            Section {
                Toggle("Enable equalizer", isOn: $app.equalizerEnabled)
                    .tint(MusicDesign.accent)
                if app.equalizerEnabled {
                    Toggle("Bypass", isOn: $app.equalizerBypass)
                        .tint(MusicDesign.accent)
                }
            } footer: {
                Text("EQ applies to downloads and cached streams. New streams start playing right away and switch to EQ automatically once cached locally (usually within a few seconds on Wi‑Fi).")
            }

            if app.equalizerEnabled {
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
                }

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
        }
        .navigationTitle("Equalizer")
        .settingsSubpageChrome()
        .onAppear {
            if !EqualizerPreset.catalog.contains(where: { $0.id == app.equalizerPresetId }) {
                app.equalizerPresetId = EqualizerPreset.catalog[0].id
            }
        }
    }

    private func equalizerBandRow(index: Int) -> some View {
        let frequency = Int(EqualizerBand.frequencies[index])
        let label = frequency >= 1_000 ? String(format: "%.0f kHz", Double(frequency) / 1_000) : "\(frequency) Hz"
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
                Text(label)
                Spacer()
                Text(gainLabel(gainBinding.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: gainBinding,
                in: EqualizerBand.gainRange,
                step: 0.5,
            )
            .tint(MusicDesign.accent)
        }
        .padding(.vertical, 2)
    }

    private func gainLabel(_ gain: Float) -> String {
        if gain > 0 { return String(format: "+%.1f dB", gain) }
        return String(format: "%.1f dB", gain)
    }
}
