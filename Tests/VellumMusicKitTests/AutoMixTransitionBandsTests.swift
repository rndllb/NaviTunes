import Foundation
import Testing

@testable import VellumMusicKit

/// T677. The blend's bass hand-over and filter sweep now run inside the equalizer tap, as two
/// extra biquads after the ten bands, on whichever `AVPlayer` carries each song. Pure maths.
@Suite("AutoMix transition bands in the tap")
struct AutoMixTransitionBandsTests {
    static let rate = 44_100.0

    @Test("the low shelf cuts the bass and leaves the rest alone")
    func lowShelf() {
        let c = TapBiquad.lowShelf(frequency: 150, gainDB: -18, sampleRate: Self.rate)
        #expect(abs(TapBiquad.gainDB(c, frequency: 20, sampleRate: Self.rate) - (-18)) < 0.3)
        #expect(abs(TapBiquad.gainDB(c, frequency: 60, sampleRate: Self.rate) - (-18)) < 1.5)
        #expect(abs(TapBiquad.gainDB(c, frequency: 150, sampleRate: Self.rate) - (-9)) < 0.5)   // half the cut at the corner
        #expect(abs(TapBiquad.gainDB(c, frequency: 2000, sampleRate: Self.rate)) < 0.2)
        #expect(abs(TapBiquad.gainDB(c, frequency: 10_000, sampleRate: Self.rate)) < 0.1)
        #expect(TapBiquad.lowShelf(frequency: 150, gainDB: 0, sampleRate: Self.rate) == .identity)
        #expect(TapBiquad.lowShelf(frequency: 150, gainDB: -18, sampleRate: 0) == .identity)
    }

    @Test("the low-pass is −3 dB at the cutoff, open at 20 kHz, and identity when asked for none")
    func lowPass() {
        let c = TapBiquad.lowPass(frequency: 800, sampleRate: Self.rate)
        #expect(abs(TapBiquad.gainDB(c, frequency: 800, sampleRate: Self.rate) - (-3)) < 0.3)
        #expect(abs(TapBiquad.gainDB(c, frequency: 100, sampleRate: Self.rate)) < 0.1)
        #expect(TapBiquad.gainDB(c, frequency: 8000, sampleRate: Self.rate) < -35)
        #expect(TapBiquad.lowPass(frequency: 20_000, sampleRate: Self.rate) == .identity)
        #expect(TapBiquad.lowPass(frequency: 25_000, sampleRate: Self.rate) == .identity)
    }

    @Test("the tap carries the two transition bands after the ten and starts them flat")
    func tapBands() {
        let tap = EqualizerAudioTap(trackId: "t", trackTitle: "t", gains: EqualizerBand.flatGains, bypassed: false)
        #expect(Int(tap.state.pointee.bandCount) == EqualizerBand.count + EqualizerAudioTap.transitionBandCount)
        #expect(tap.transition.bassDB == 0 && tap.transition.lowPassHz == nil)
        tap.setTransition(bassDB: -18, lowPassHz: 4000)
        #expect(tap.transition.bassDB == -18 && tap.transition.lowPassHz == 4000)
        #expect(!tap.hasAudibleCurve)   // the EQ's own question is unchanged by a transition
        tap.disposeBeforeAttachment()
    }

    @Test("the incoming song's gain curve as ramps: from silence at mix-in, equal-power, to unity after the settle")
    func ramps() {
        let plan = CrossfadePlan(outgoingMixOut: 200, incomingMixIn: 4, duration: 8, incomingGainDB: 2, filterSweep: true, reason: .tempoMismatch)
        let automation = AutoMixAutomation(crossfade: plan)
        let ramps = AutoMixPlayerBlend.incomingVolumeRamps(automation)
        #expect(ramps.count == 100)                       // 8 s overlap + 2 s trim glide at 0.1 s
        #expect(ramps.first?.start == 4 && ramps.first?.from == 0)
        #expect(abs((ramps.last?.end ?? 0) - 14) < 1e-9)
        #expect(abs((ramps.last?.to ?? 0) - 1) < 1e-6)
        // Contiguous and monotone in time.
        for (a, b) in zip(ramps, ramps.dropFirst()) { #expect(abs(a.end - b.start) < 1e-9 && b.end > b.start) }
        // Halfway through the fade: equal-power sin(45°) × the +2 dB trim.
        let mid = ramps[40]
        #expect(abs(mid.from - Float(sin(Double.pi / 4)) * 1.2589) < 0.01)
        // At the end of the overlap the trim is still on; the glide takes it to 1.
        #expect(abs(ramps[79].to - 1.2589) < 0.01)
        #expect(ramps[89].to < ramps[79].to && ramps[89].to > 1)
        // Beat-matched: item time runs through the rate schedule, so ramps are shorter in item time than output time.
        let blend = BlendPlan(outgoingMixOut: 200, incomingMixIn: 8, overlapDuration: 16, overlapBars: 8, incomingRate: 0.96,
                              rateSchedule: [], rateGlideDuration: 8, incomingGainDB: -3, bassSwapFraction: 0.5, sectionAligned: true)
        let b = AutoMixPlayerBlend.incomingVolumeRamps(AutoMixAutomation(plan: blend))
        #expect(abs((b.first?.end ?? 0) - (b.first?.start ?? 0) - 0.096) < 1e-6)
        #expect(AutoMixPlayerBlend.initialRate(AutoMixAutomation(plan: blend)) == 0.96)
        #expect(AutoMixPlayerBlend.initialRate(automation) == 1)
    }

    @Test("the overlap start is the host time the outgoing reaches its mix-out, or nil when that is behind")
    func overlapStart() {
        let now: UInt64 = 1_000_000_000
        let start = AutoMixPlayerBlend.overlapStart(outgoingPosition: 194, mixOut: 200, now: now)
        #expect(start != nil)
        #expect(abs(AutoMixHostClock.seconds(from: now, to: start!) - 6) < 0.001)
        #expect(AutoMixPlayerBlend.overlapStart(outgoingPosition: 200.01, mixOut: 200, now: now) == nil)
        #expect(AutoMixPlayerBlend.overlapStart(outgoingPosition: 199.99, mixOut: 200, now: now) == nil)
    }
}
