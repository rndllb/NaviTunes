import AVFoundation
import SwiftUI

/// Guided hearing sensitivity test — plays a tone per band and maps the audible
/// threshold to an EQ compensation curve.
struct EqualizerHearingTestView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var stepIndex = 0
    @State private var offsets: [Float] = EqualizerBand.flatGains
    @State private var toneLevel: Float = 1.0
    @State private var isPlayingTone = false
    @State private var engine: AVAudioEngine?
    @State private var playerNode: AVAudioPlayerNode?

    var body: some View {
        List {
            Section {
                Text("Play the tone at full volume, then lower the slider until it is barely audible. Tap Next to record that band's threshold.")
                    .font(.subheadline)
                    .foregroundStyle(MusicDesign.secondaryLabel)
            }

            if stepIndex < EqualizerBand.count {
                let frequency = EqualizerBand.frequencies[stepIndex]
                Section {
                    Text(bandLabel(frequency))
                        .font(.title3.weight(.semibold))
                    HStack {
                        Text("Tone level")
                        Spacer()
                        Text("\(Int(toneLevel * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $toneLevel, in: 0.02 ... 1, step: 0.02)
                        .tint(MusicDesign.accent)
                        .onChange(of: toneLevel) { _, _ in
                            updateToneVolume()
                        }
                    Button(isPlayingTone ? "Stop tone" : "Play tone") {
                        if isPlayingTone {
                            stopTone()
                        } else {
                            playTone(frequency: frequency)
                        }
                    }
                } header: {
                    Text("Band \(stepIndex + 1) of \(EqualizerBand.count)")
                } footer: {
                    Text("Start at full volume and lower until you can just barely hear the tone. The quieter the threshold, the more compensation is applied.")
                }
            } else {
                Section {
                    EqualizerCurveGraphView(gains: offsets, height: 120)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    Button("Apply hearing profile") {
                        app.applyHearingTestOffsets(offsets)
                        dismiss()
                    }
                } header: {
                    Text("Result")
                }
            }
        }
        .navigationTitle("Hearing Test")
        .musicNavigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    stopTone()
                    dismiss()
                }
            }
            if stepIndex < EqualizerBand.count {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") {
                        saveCurrentBand()
                        stopTone()
                        stepIndex += 1
                        if stepIndex < EqualizerBand.count {
                            toneLevel = 1.0
                        }
                    }
                }
            }
        }
        .onDisappear { stopTone() }
    }

    private func saveCurrentBand() {
        // Quieter tone needed → more high-frequency boost compensation.
        let compensation = (1 - toneLevel) * 10
        offsets[stepIndex] = min(max(compensation, 0), EqualizerBand.gainRange.upperBound)
    }

    private func bandLabel(_ frequency: Float) -> String {
        let value = Int(frequency)
        return value >= 1_000 ? String(format: "%.0f kHz", Double(value) / 1_000) : "\(value) Hz"
    }

    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
        #endif
    }

    private func playTone(frequency: Float) {
        stopTone()
        activateAudioSession()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let sampleRate = 44_100.0
        let duration = 1.5
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }

        buffer.frameLength = frameCount
        let theta = 2 * Double.pi * Double(frequency) / sampleRate
        let amplitude = Double(toneAmplitude(for: frequency) * toneLevel)
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0 ..< Int(frameCount) {
                channel[frame] = Float(sin(theta * Double(frame)) * amplitude)
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1

        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.playerNode = player
            isPlayingTone = true
        } catch {
            stopTone()
        }
    }

    private func updateToneVolume() {
        guard isPlayingTone, let engine else { return }
        engine.mainMixerNode.outputVolume = toneLevel
    }

    private func toneAmplitude(for frequency: Float) -> Float {
        switch frequency {
        case ..<80: return 0.9
        case ..<250: return 0.55
        case ..<2_000: return 0.35
        default: return 0.28
        }
    }

    private func stopTone() {
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
        isPlayingTone = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
