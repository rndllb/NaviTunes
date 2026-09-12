import AVFoundation
import Foundation

/// A periodic time observer kept together with the `AVPlayer` that vended it.
///
/// `AVPlayer.addPeriodicTimeObserver` returns an opaque token, and
/// `AVPlayer.removeTimeObserver(_:)` raises an **Objective-C exception** — not a Swift error — when
/// handed a token some *other* player created. There is no `try` that catches it: it reaches
/// `objc_terminate` and aborts the process.
///
/// `PlaybackEngine` stored the token in one property (`timeObserver: Any?`) while the player
/// underneath it was replaced freely — on a fresh load, after a failure, after an audio-session
/// interruption. `bindItemObservers` set the context to the **new** player and immediately
/// reinstalled, so the reinstall handed the new player the **old** player's token and the app
/// aborted. Four of the eleven crash reports off the device are that abort, including three in the
/// hour after the T264 fix shipped, on the advance path:
///
///     objc_exception_throw → AVFCore → PlaybackEngine.installPeriodicTimeObserver()
///     → bindItemObservers → attachPlayer → loadAVPlayerItem → advance()
///
/// The pairing is the fix, and it is structural rather than defensive: the token is never stored
/// without the player that produced it, and `remove()` is the only path that consumes it, so there
/// is no expression in this type that can pass a token to a foreign player. Nothing is caught,
/// because nothing can be thrown.
///
/// `player` is `weak` on purpose. A player that has already been deallocated took its observers
/// with it, so there is nothing left to remove and holding it alive just to say so would be worse
/// than doing nothing.
final class PeriodicTimeObserverBinding {
    private struct Bound {
        weak var player: AVPlayer?
        let token: Any
    }

    private var bound: Bound?

    /// True while an observer is installed. The player may still have gone away underneath it.
    var isInstalled: Bool { bound != nil }

    /// The player currently being observed, or nil if none is installed or it was deallocated.
    var observedPlayer: AVPlayer? { bound?.player }

    /// Installs on `player`, first removing any previous observer **from its own player**.
    ///
    /// Safe to call when the player has changed — that is the case it exists for.
    func install(
        on player: AVPlayer,
        interval: CMTime,
        queue: DispatchQueue = .main,
        handler: @escaping @Sendable (CMTime) -> Void
    ) {
        remove()
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: queue, using: handler)
        bound = Bound(player: player, token: token)
    }

    /// Removes the installed observer from the player that created it. Idempotent.
    func remove() {
        guard let existing = bound else { return }
        // Cleared before the call so a throw could not leave a consumed token installed. Nothing
        // here can throw, but the ordering costs nothing and keeps that true if this is edited.
        bound = nil
        existing.player?.removeTimeObserver(existing.token)
    }
}
