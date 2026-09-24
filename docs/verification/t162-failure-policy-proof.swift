import AVFoundation
import Foundation

// T162: auto-skip an unplayable song — proof for the two decisions that matter.
//
// This does NOT restate the shipping logic. It is compiled *against* it: the shipping file is
// passed to swiftc alongside this driver, so `PlaybackFailurePolicy`, `PlaybackFailureReason`
// and `PlaybackFailureStreak` here are the same declarations the app ships. If the policy
// changes and this proof still passes, the proof is still telling the truth.
//
//   swiftc Sources/VellumMusicKit/PlaybackFailurePolicy.swift \
//          docs/verification/t162-failure-policy-proof.swift -o /tmp/t162proof && /tmp/t162proof

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    print("\(passed ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
    if !passed { failures += 1 }
}

func expect(_ label: String, _ got: PlaybackFailureReason, _ want: PlaybackFailureReason) {
    check(label, got == want, "got \(got), want \(want)")
}

// Errors shaped the way AVFoundation actually delivers them: an AVFoundationErrorDomain
// wrapper with the real cause under NSUnderlyingErrorKey, sometimes two deep.
func avWrapped(_ underlying: NSError, code: Int = -11800) -> NSError {
    NSError(domain: AVFoundationErrorDomain, code: code,
            userInfo: [NSUnderlyingErrorKey: underlying])
}
func urlErr(_ code: URLError.Code) -> NSError {
    NSError(domain: NSURLErrorDomain, code: code.rawValue)
}

@main
struct T162Proof {
    static func main() {
        print("== classification: transient vs permanent ==")

        // The failure the user hit: the server was down. Must NOT read as a bad file, and must retry.
        let serverDown = avWrapped(urlErr(.cannotConnectToHost))
        expect("server refused connection -> unreachable", PlaybackFailurePolicy.classify(serverDown), .unreachable)
        check("  ...and is retried before skipping", PlaybackFailurePolicy.classify(serverDown).isTransient)
        check("  ...and reads as a server problem", PlaybackFailurePolicy.classify(serverDown).isServerSide)

        expect("dropped Wi-Fi -> unreachable", PlaybackFailurePolicy.classify(avWrapped(urlErr(.networkConnectionLost))), .unreachable)
        expect("DNS failure -> unreachable", PlaybackFailurePolicy.classify(avWrapped(urlErr(.cannotFindHost))), .unreachable)
        expect("load timeout -> unreachable", PlaybackFailurePolicy.classify(URLError(.timedOut)), .unreachable)

        // A file the decoder rejected. Retrying identical bytes cannot help, so it must not retry.
        let decoderReject = avWrapped(NSError(domain: NSOSStatusErrorDomain, code: -12847))
        expect("decoder OSStatus -> undecodable", PlaybackFailurePolicy.classify(decoderReject), .undecodable)
        check("  ...and is skipped immediately", !PlaybackFailurePolicy.classify(decoderReject).isTransient)
        check("  ...and does NOT read as a server problem", !PlaybackFailurePolicy.classify(decoderReject).isServerSide)

        expect("AVError.decodeFailed -> undecodable",
               PlaybackFailurePolicy.classify(NSError(domain: AVFoundationErrorDomain, code: AVError.decodeFailed.rawValue)),
               .undecodable)
        expect("unparseable response -> undecodable",
               PlaybackFailurePolicy.classify(URLError(.cannotParseResponse)), .undecodable)

        print()
        print("== the HTTP status is what separates a dead track from a dead server ==")

        // NSURLErrorDomain collapses every non-2xx into .badServerResponse. Without the status code
        // from AVPlayerItem.errorLog(), a 404 and a 503 are the same error object.
        let ambiguous = avWrapped(urlErr(.badServerResponse))
        expect("404 -> missingOnServer", PlaybackFailurePolicy.classify(ambiguous, httpStatus: 404), .missingOnServer)
        expect("410 -> missingOnServer", PlaybackFailurePolicy.classify(ambiguous, httpStatus: 410), .missingOnServer)
        expect("503 -> serverError", PlaybackFailurePolicy.classify(ambiguous, httpStatus: 503), .serverError)
        expect("502 -> serverError", PlaybackFailurePolicy.classify(ambiguous, httpStatus: 502), .serverError)
        expect("429 -> serverError", PlaybackFailurePolicy.classify(ambiguous, httpStatus: 429), .serverError)
        expect("408 -> serverError", PlaybackFailurePolicy.classify(ambiguous, httpStatus: 408), .serverError)
        expect("401 -> unauthorized", PlaybackFailurePolicy.classify(ambiguous, httpStatus: 401), .unauthorized)
        check("404 is skipped, 503 is retried",
              !PlaybackFailurePolicy.classify(ambiguous, httpStatus: 404).isTransient
              && PlaybackFailurePolicy.classify(ambiguous, httpStatus: 503).isTransient)
        check("no status recovered still errs toward retrying",
              PlaybackFailurePolicy.classify(ambiguous).isTransient,
              "\(PlaybackFailurePolicy.classify(ambiguous))")

        print()
        print("== the runaway guard ==")

        check("threshold is 3", PlaybackFailurePolicy.haltThreshold == 3, "\(PlaybackFailurePolicy.haltThreshold)")

        var streak = PlaybackFailureStreak()
        check("1st dead file does not halt", streak.recordFailure(.missingOnServer) == nil)
        check("2nd dead file does not halt", streak.recordFailure(.undecodable) == nil)
        let tripped = streak.recordFailure(.missingOnServer)
        check("3rd dead file halts", tripped != nil)
        check("  ...and blames the files, not the server", tripped?.isServerSide == false)
        check("  ...and says how many failed", tripped?.failureCount == 3, "\(tripped?.failureCount ?? -1)")
        check("  ...and the counter is armed again, not stuck", streak.count == 0, "\(streak.count)")

        var outage = PlaybackFailureStreak()
        _ = outage.recordFailure(.unreachable)
        _ = outage.recordFailure(.unreachable)
        let outageHalt = outage.recordFailure(.serverError)
        check("3 server failures halt", outageHalt != nil)
        check("  ...and blame the server", outageHalt?.isServerSide == true)
        check("  ...and the message says so, not 'nothing to play'",
              (outageHalt?.message.contains("not an empty playlist") ?? false)
              && (outageHalt?.message.contains("Check that the server is running") ?? false))

        // One dead file inside an outage must not flip the diagnosis away from the outage.
        var mixed = PlaybackFailureStreak()
        _ = mixed.recordFailure(.unreachable)
        _ = mixed.recordFailure(.undecodable)
        let mixedHalt = mixed.recordFailure(.unreachable)
        check("outage + 1 bad file still blames the server", mixedHalt?.isServerSide == true)

        // ...and the reverse: one blip inside a run of bad files must not blame the server.
        var mostlyBad = PlaybackFailureStreak()
        _ = mostlyBad.recordFailure(.undecodable)
        _ = mostlyBad.recordFailure(.unreachable)
        let mostlyBadHalt = mostlyBad.recordFailure(.missingOnServer)
        check("2 bad files + 1 blip blames the files", mostlyBadHalt?.isServerSide == false)

        // A good track between failures must reset the count, or a long session accumulates a halt.
        var interrupted = PlaybackFailureStreak()
        _ = interrupted.recordFailure(.missingOnServer)
        _ = interrupted.recordFailure(.missingOnServer)
        interrupted.reset()
        check("a song that plays clears the streak",
              interrupted.recordFailure(.missingOnServer) == nil && interrupted.count == 1,
              "count=\(interrupted.count)")

        print()
        print("== every reason has user-facing copy ==")
        for reason: PlaybackFailureReason in [.missingOnServer, .undecodable, .unreachable, .serverError, .unauthorized, .unknown] {
            check("\(reason) has a skip clause", !reason.skipClause.isEmpty, reason.skipClause)
        }

        print()
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
