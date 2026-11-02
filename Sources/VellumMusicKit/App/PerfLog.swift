import Foundation
import os

/// Centralized perf instrumentation for the library/sync hot paths.
///
/// Wraps a block in a timer that emits an `os.Logger` entry (visible in Console.app
/// under subsystem `vellum.perf`) and a signpost (visible in Instruments → Logging /
/// os_signpost). The logger output stays quiet unless a block exceeds
/// ``slowThresholdMs`` so the noise floor is low; signposts always fire so traces
/// captured in Instruments have full coverage.
///
/// Designed to surface main-thread hangs on large libraries — anything tagged
/// ``ctx: .mainActor`` that runs longer than 16 ms (one frame at 60 Hz) is logged
/// at `.notice` level with the duration and a free-form `details` string.
enum PerfLog {
    enum Context: String { case mainActor, background, network }

    /// Frame budget at 60 Hz. Anything on the main actor longer than this drops
    /// frames; cross this threshold and we log at `.notice`.
    static let mainActorFrameMs: Double = 16

    /// Slower threshold for clearly heavy ops (snapshot encode, index rebuild)
    /// where short bursts are expected. Crossing this is logged at `.error`.
    static let mainActorHangMs: Double = 250

    private static let logger = Logger(subsystem: "vellum.perf", category: "library")
    private static let signposter = OSSignposter(subsystem: "vellum.perf", category: .pointsOfInterest)

    @discardableResult
    static func measure<T>(
        _ label: StaticString,
        context: Context = .mainActor,
        details: String = "",
        _ body: () throws -> T,
    ) rethrows -> T {
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval(label, id: signpostID)
        let start = ContinuousClock.now
        defer {
            let elapsed = (ContinuousClock.now - start).milliseconds
            signposter.endInterval(label, state)
            emit(label: label, context: context, ms: elapsed, details: details)
        }
        return try body()
    }

    @discardableResult
    static func measureAsync<T>(
        _ label: StaticString,
        context: Context = .mainActor,
        details: String = "",
        _ body: () async throws -> T,
    ) async rethrows -> T {
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval(label, id: signpostID)
        let start = ContinuousClock.now
        do {
            let result = try await body()
            let elapsed = (ContinuousClock.now - start).milliseconds
            signposter.endInterval(label, state)
            emit(label: label, context: context, ms: elapsed, details: details)
            return result
        } catch {
            let elapsed = (ContinuousClock.now - start).milliseconds
            signposter.endInterval(label, state)
            emit(label: label, context: context, ms: elapsed, details: "\(details) [threw \(type(of: error))]")
            throw error
        }
    }

    /// Stamp a one-shot event (no duration). Useful for "size landed: N items"
    /// markers that show up in Instruments alongside the interval signposts.
    static func event(_ label: StaticString, details: String = "") {
        signposter.emitEvent(label)
        logger.debug("\(String(describing: label), privacy: .public) — \(details, privacy: .public)")
    }

    private static func emit(label: StaticString, context: Context, ms: Double, details: String) {
        let ctxName = context.rawValue
        let pretty = String(format: "%.1f", ms)
        let detailFragment = details.isEmpty ? "" : " | \(details)"
        if context == .mainActor && ms >= mainActorHangMs {
            logger.error("[\(ctxName, privacy: .public)] \(String(describing: label), privacy: .public) — \(pretty, privacy: .public)ms HANG\(detailFragment, privacy: .public)")
        } else if context == .mainActor && ms >= mainActorFrameMs {
            logger.notice("[\(ctxName, privacy: .public)] \(String(describing: label), privacy: .public) — \(pretty, privacy: .public)ms\(detailFragment, privacy: .public)")
        } else {
            logger.debug("[\(ctxName, privacy: .public)] \(String(describing: label), privacy: .public) — \(pretty, privacy: .public)ms\(detailFragment, privacy: .public)")
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        let comps = components
        return Double(comps.seconds) * 1_000 + Double(comps.attoseconds) / 1_000_000_000_000_000
    }
}
