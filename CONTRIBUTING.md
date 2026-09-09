# Contributing

## Branching

`main` and `dev` are protected. Neither accepts a direct push — everything arrives by pull
request.

```
feature branch  ──PR──▶  dev  ──PR──▶  main
```

- **Work happens on a branch off `dev`.** Name it for the work (`fix/lyrics-offset`,
  `feat/radio-search`), not for yourself.
- **A PR into `dev`** needs a passing `build-and-test` check and one approving review. You
  cannot approve your own PR, so every merge involves the other person.
- **A PR from `dev` into `main`** is the release step, under the same rules. `main` accepts
  PRs from `dev` only.

Admins do not bypass these rules. That is deliberate: a guardrail only one person can walk
around isn't one.

## CI

`.github/workflows/ci.yml` runs on pull requests into `dev` and `main` — not on every push,
because macOS runners bill at 10x on private repos.

The job builds the host app and runs the `VellumMusicKit` unit tests on an iOS Simulator:

```
xcodebuild test \
  -workspace VellumMusic.xcworkspace \
  -scheme VellumMusicKitTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

That same command is what to run locally before opening a PR.

`VellumMusicUITests` is deliberately **not** in that scheme. It drives a real signed-in
Navidrome/Jellyfin server, so it can't run on a clean runner and would be flaky if it did.
Run it locally when you touch navigation.

## Tests

Unit tests live in `Tests/VellumMusicKitTests/` and use
[Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`, `@Test`,
`#expect`).

The package is iOS-only — `Sources/VellumMusicKit` uses SwiftUI APIs unavailable on macOS — so
`swift test` does not work. Tests must run through an iOS Simulator destination via the
`VellumMusicKitTests` scheme. For the same reason the package is listed as a member of
`VellumMusic.xcworkspace`: as a bare package *dependency* its test target isn't buildable and
the scheme resolves to "no test bundles available".

### What belongs here

Pure, deterministic logic whose breakage is quiet — the kind that ships without a crash and is
noticed weeks later. Current suites cover `LibraryMembership` (magic-playlist identity, and the
predicate that keeps the library out of the playlist editor) and `GenreCanonicalizer` (an
ordered first-match-wins table where reordering one rule silently rehomes others).

Anything needing a live server, a real player, or a view hierarchy does not belong in this
target.

### One gotcha

`#expect` cannot hoist a `rethrows` call. `#expect(x.allSatisfy(\.isHexDigit))` fails to
compile with "call can throw"; bind it to a `let` first and expect the result.
