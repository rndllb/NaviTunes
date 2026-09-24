import Foundation

// T136: does "Go to Artist" land on the artist you tapped, when two artists share a name?
// Uses two real artists both named exactly "Rocket" (MusicBrainz), standing in for two server
// rows of the same name.
@main
struct Main {
    static func main() {
        func line(_ s: String) { print(s) }
        line("=== T136: same-name 'Go to Artist' resolution ===")
        line("case: two distinct artists, both named exactly \"Rocket\"")

        let rocketRapper = "9e2f71c3-1e8d-4fec-81af-d984bb88eb94"   // ROCKET, Russian rapper
        let rocketIndie  = "9563966d-ca18-44f7-9d72-87a1fe27ae9d"   // Rocket, indie rock, Los Angeles

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String) {
            if !ok { failures += 1 }
            line("  [\(ok ? "PASS" : "FAIL")] \(label): \(detail)")
        }

        // With an id — the new path.
        for (label, id) in [("Russian rapper", rocketRapper), ("indie rock band", rocketIndie)] {
            let nav = ArtistNameNavigation(id: "Rocket", serverArtistId: id)
            switch nav.artistPageInput {
            case .libraryArtist(let a):
                check("tapping the \(label)'s track", a.id == id,
                      "resolved to artist id \(a.id.prefix(8))… (name was \"\(a.name)\")")
            case .named(let n):
                check("tapping the \(label)'s track", false, "fell back to name \"\(n)\" — ambiguous")
            }
        }

        // The two navigations must be distinguishable from each other.
        let a = ArtistNameNavigation(id: "Rocket", serverArtistId: rocketRapper)
        let b = ArtistNameNavigation(id: "Rocket", serverArtistId: rocketIndie)
        check("the two Rockets are different destinations", a.artistPageInput != b.artistPageInput,
              "same display name, different resolved artist")

        // Without an id — the surviving risk, asserted so it is not mistaken for fixed.
        let nameOnly = ArtistNameNavigation(id: "Rocket")
        if case .named(let n) = nameOnly.artistPageInput {
            check("with no id, it still falls back to a name", true,
                  "\"\(n)\" — one of 18 exact matches, so the destination is a guess")
        } else {
            check("with no id, it still falls back to a name", false, "unexpectedly resolved by id")
        }

        line(failures == 0 ? "VERDICT: PASS" : "VERDICT: FAIL (\(failures))")
    }
}
