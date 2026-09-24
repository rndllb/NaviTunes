import Foundation

// T148: does tapping the artist on a Discover request row land on a person, or on a credit line?
//
// Driven by the real MusicBrainz payload for the reported track — Rich Brian's "Is It?", credited
// to three artists — saved verbatim alongside this file as `t148-is-it-recording.json`. The types
// and the two navigation decisions below are extracted verbatim from the shipping source
// (`MusicBrainzModels.swift`, `MusicBrainzDiscographyMapping.swift`, `AcquisitionCore.swift`,
// `DiscoverySearchView.swift`), so this proves the app's behaviour rather than a restatement of it.
//
//   swiftc docs/verification/t148-credit-line-nav-proof.swift -o /tmp/t148 && /tmp/t148

// MARK: - Shipping types, verbatim

struct MusicBrainzCreditedArtist: Codable, Hashable {
    let id: String
    let name: String
}

struct MusicBrainzArtistCredit: Codable, Hashable {
    let name: String?
    let joinphrase: String?
    let artist: MusicBrainzCreditedArtist?
}

extension Array where Element == MusicBrainzArtistCredit {
    /// `MusicBrainzModels.swift` — the credit line as MusicBrainz intends it to read.
    var creditLine: String {
        var out = ""
        for credit in self {
            let name = credit.name ?? credit.artist?.name ?? ""
            guard !name.isEmpty else { continue }
            if !out.isEmpty, out.last?.isWhitespace == false, credit.joinphrase == nil {
                out += ", "
            }
            out += name
            if let join = credit.joinphrase, !join.isEmpty { out += join }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var primaryArtistMBID: String? { first?.artist?.id }
    var primaryArtistName: String? { first?.artist?.name ?? first?.name }
}

/// The destination an artist tap produces. `.named` is the name-lookup path; `.musicBrainzArtistId`
/// is the identified one. `ArtistPageInput.displayName` is the page's title in both cases, which is
/// why the `name` in the id case still matters.
enum ArtistPageInput: Equatable {
    case named(String)
    case musicBrainzArtistId(id: String, name: String)

    var displayName: String {
        switch self {
        case .named(let n): return n
        case .musicBrainzArtistId(_, let name): return name
        }
    }

    var resolvesByIdentity: Bool {
        if case .musicBrainzArtistId = self { return true }
        return false
    }
}

// MARK: - The row, before and after

/// BEFORE (commit 9579592): `MusicBrainzSongRow.artist` is the credit line, and
/// `asAcquisitionResult` put it straight into `AcquisitionResult.artists`. `acquireRowSubtitle`
/// (`DiscoverySearchView.swift:1509,1525`) then read `artists.first` as a name.
func beforeFix(credit: [MusicBrainzArtistCredit]) -> ArtistPageInput {
    let artists = [credit.creditLine]                 // asAcquisitionResult, before
    let name = artists.first ?? ""                    // acquireRowSubtitle, `let artist =`
    return .named(name)                               // SearchNavTarget.namedArtist(artist)
}

/// AFTER: `artists` holds the primary credit's own name, the credit line rides alongside in
/// `artistCreditLine`, and `SearchNavTarget.primaryArtist(of:)` prefers `request.artistMBID`.
func afterFix(credit: [MusicBrainzArtistCredit]) -> (label: String, input: ArtistPageInput?) {
    let artists = [credit.primaryArtistName ?? ""].filter { !$0.isEmpty }
    let artistCreditLine: String? = credit.creditLine
    let artistMBID = credit.primaryArtistMBID

    let label = artistCreditLine ?? artists.joined(separator: ", ")   // displayArtistLine
    guard let name = artists.first, !name.isEmpty else { return (label, nil) }
    if let mbid = artistMBID, !mbid.isEmpty {
        return (label, .musicBrainzArtistId(id: mbid, name: name))
    }
    return (label, .named(name))
}

// MARK: -

@main
struct Main {
    static func main() {
        func line(_ s: String) { print(s) }
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String) {
            if !ok { failures += 1 }
            line("  [\(ok ? "PASS" : "FAIL")] \(label): \(detail)")
        }

        let path = "docs/verification/t148-is-it-recording.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordings = root["recordings"] as? [[String: Any]],
              let recording = recordings.first,
              let creditJSON = recording["artist-credit"],
              let creditData = try? JSONSerialization.data(withJSONObject: creditJSON),
              let credit = try? JSONDecoder().decode([MusicBrainzArtistCredit].self, from: creditData)
        else {
            line("could not read \(path) — run from the repo root")
            exit(1)
        }

        let title = recording["title"] as? String ?? "?"
        line("=== T148: the artist a request row's credit line navigates to ===")
        line("case: \"\(title)\", MusicBrainz recording \(recording["id"] as? String ?? "?")")
        line("      credited to \(credit.count) artists")
        line("")

        line("credit line as rendered: \"\(credit.creditLine)\"")
        line("primary credit:          \"\(credit.primaryArtistName ?? "—")\" (\(credit.primaryArtistMBID ?? "no id"))")
        line("")

        // The defect, asserted as a *reproduction*: these two checks PASS when the reported bug is
        // present, which is what makes them evidence. Inverting them would make the file a second
        // copy of the fix rather than a demonstration of what was wrong.
        line("BEFORE — DiscoverySearchView.swift:1525, SearchNavTarget.namedArtist(artists.first)")
        let before = beforeFix(credit: credit)
        check("reproduced: the page is titled with the whole credit line",
              before.displayName == credit.creditLine,
              "titled \"\(before.displayName)\" — nobody is called that")
        check("reproduced: the destination is a name lookup, so it resolves to nothing",
              !before.resolvesByIdentity,
              "SearchNavTarget.namedArtist(\"\(before.displayName)\")")
        line("")

        // The fix.
        line("AFTER — SearchNavTarget.primaryArtist(of:)")
        let after = afterFix(credit: credit)
        check("the row still shows everyone on the record",
              after.label == credit.creditLine,
              "label \"\(after.label)\"")
        check("the artist page is titled with a person's name",
              after.input?.displayName == credit.primaryArtistName,
              "titled \"\(after.input?.displayName ?? "—")\"")
        check("the destination is an identity, not a name lookup",
              after.input?.resolvesByIdentity == true,
              {
                  if case .musicBrainzArtistId(let id, _)? = after.input { return "MBID \(id)" }
                  return "by name"
              }())
        check("that identity is the primary credit's own MBID",
              {
                  if case .musicBrainzArtistId(let id, _)? = after.input { return id == credit.primaryArtistMBID }
                  return false
              }(),
              credit.primaryArtistMBID ?? "—")
        line("")

        // The label and the destination are allowed to differ. That is the whole point, and it is
        // asserted so a later "simplification" that collapses them back into one string fails here.
        check("label and destination are deliberately different strings",
              after.label != after.input?.displayName,
              "\"\(after.label)\" is rendered, \"\(after.input?.displayName ?? "—")\" is opened")

        // The two other credited artists must not be reachable *as one artist*. Nothing should ever
        // navigate to a string containing more than one of them.
        let othersInDestination = credit.dropFirst().compactMap { $0.artist?.name }
            .filter { after.input?.displayName.contains($0) == true }
        check("no second artist leaks into the destination name",
              othersInDestination.isEmpty,
              othersInDestination.isEmpty ? "none" : othersInDestination.joined(separator: ", "))

        line("")
        line(failures == 0 ? "VERDICT: PASS" : "VERDICT: FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
