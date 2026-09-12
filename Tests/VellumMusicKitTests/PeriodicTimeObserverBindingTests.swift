import AVFoundation
import Foundation
import Testing

@testable import VellumMusicKit

/// Reproduces the sequence behind four of the eleven crash reports pulled off the device, three of
/// them in the hour after the T264 fix shipped: an observer installed on one `AVPlayer`, the player
/// replaced without the orderly teardown running, then the next advance reinstalling.
///
/// The old code stored the token alone and removed it from whichever player was current, so that
/// third step handed player B a token player A had vended. `AVPlayer.removeTimeObserver` raises an
/// Objective-C exception for that, which Swift cannot catch — it aborts the process. These tests
/// therefore assert by *completing*: a failure here is not a red assertion, it is the test runner
/// dying with `EXC_CRASH / SIGABRT`, exactly as the phone did.
@Suite("Periodic time observer binding")
struct PeriodicTimeObserverBindingTests {
    private static let interval = CMTime(seconds: 0.35, preferredTimescale: 600)

    /// The crash, step for step.
    @Test("reinstalling after the player is replaced does not hand B an observer A created")
    func reinstallAfterPlayerReplacement() {
        let binding = PeriodicTimeObserverBinding()

        let playerA = AVPlayer()
        binding.install(on: playerA, interval: Self.interval) { _ in }
        #expect(binding.observedPlayer === playerA)

        // The player is swapped with no teardown — what an interruption-recovery or failure path
        // does before the next advance.
        let playerB = AVPlayer()

        // The advance. Previously: playerB.removeTimeObserver(<token from playerA>) -> abort.
        binding.install(on: playerB, interval: Self.interval) { _ in }
        #expect(binding.observedPlayer === playerB)
    }

    /// Several advances in a row, each with a fresh player — a queue playing through.
    @Test("a run of player replacements stays paired")
    func repeatedReplacementsStayPaired() {
        let binding = PeriodicTimeObserverBinding()
        var players: [AVPlayer] = []
        for _ in 0 ..< 5 {
            let p = AVPlayer()
            players.append(p)
            binding.install(on: p, interval: Self.interval) { _ in }
            #expect(binding.observedPlayer === p)
        }
        binding.remove()
        #expect(!binding.isInstalled)
        #expect(players.count == 5)
    }

    /// The orderly teardown path (`detachPlayerKeepingQueueState`) — still works, and is idempotent
    /// so a second teardown cannot double-remove a consumed token.
    @Test("remove is idempotent and leaves nothing installed")
    func removeIsIdempotent() {
        let binding = PeriodicTimeObserverBinding()
        let player = AVPlayer()
        binding.install(on: player, interval: Self.interval) { _ in }
        #expect(binding.isInstalled)

        binding.remove()
        #expect(!binding.isInstalled)
        binding.remove()
        #expect(!binding.isInstalled)
    }

    /// A player that has already gone away took its observers with it; removal must be a no-op
    /// rather than a message to a dead object.
    @Test("removal after the observed player is deallocated is a no-op")
    func removalAfterPlayerDeallocated() {
        let binding = PeriodicTimeObserverBinding()
        autoreleasepool {
            let transient = AVPlayer()
            binding.install(on: transient, interval: Self.interval) { _ in }
            #expect(binding.observedPlayer === transient)
        }
        // Whether ARC has actually released it here is not guaranteed, so this asserts the weak
        // path is *safe* either way rather than asserting the player is gone.
        binding.remove()
        #expect(!binding.isInstalled)
    }

    /// Keeps the interval ruled out as a source of the abort: `AVPlayer` also throws for a
    /// non-numeric or non-positive interval, and the engine's two values are constants.
    @Test("the engine's observer intervals are valid positive CMTimes", arguments: [2.0, 0.35])
    func engineIntervalsAreValid(seconds: Double) {
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        #expect(t.isValid)
        #expect(t.isNumeric)
        #expect(!t.isIndefinite)
        #expect(t.seconds > 0)
    }
}
