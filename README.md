# Lyra Music

An iOS music client for self-hosted libraries. Connects to **Jellyfin** and **Navidrome** (Subsonic API), with discovery powered by Last.fm, MusicBrainz, TheAudioDB, and the iTunes Search API.

Built in SwiftUI for iOS 26, with an Apple Music–style layout: Home / New / Radio / Library / Search tabs, a full-screen Now Playing sheet, persistent mini player, and offline downloads.

## Features

- **Self-hosted backends** — sign in to Jellyfin or Navidrome with a single URL + credentials. Test the URL before logging in with the **Test Connection** button.
- **Subsonic salted-token auth** for Navidrome — the password never travels in the URL.
- **Streaming + offline** — stream FLAC/MP3/AAC over your server's native APIs, or save tracks/albums for offline playback with a structured `Artist/Album/track.ext` layout.
- **Now Playing** — Lock Screen, Control Center, AirPlay route picker, and (on iPhone) the system volume bridge.
- **Discovery** — Last.fm top charts, MusicBrainz new releases, TheAudioDB regional trending, and an iTunes-backed artwork resolver for chart entries.
- **Last.fm scrobbling** — once configured, plays scrobble automatically at the spec-correct threshold; secrets are stored in the Keychain.
- **Library tools** — favorites, server playlists (read/write where supported), per-album hero artwork with dynamic gradients, recently added / recently played shelves.
- **Search** — across library + remote discovery sources, with track-resolution against your local library so chart hits link back to your own copy.

## Project structure

```
Lyra-Music/
├── Package.swift                       # SwiftPM root
├── Sources/
│   ├── LyraMusicKit/                   # All views, models, clients, playback engine
│   └── LyraMusic/                      # Tiny SwiftPM executable shim (for `swift build`)
└── LyraMusicHost/
    ├── LyraMusicHost.xcodeproj         # The iOS app target
    └── LyraMusicHost/
        ├── LyraMusicHostApp.swift      # @main entry point
        └── Info.plist
```

`LyraMusicHost.xcodeproj` references the root `Package.swift` as a local Swift package and pulls in `LyraMusicKit`. **Only open the `.xcodeproj`** — opening `Package.swift` directly in a second Xcode window will cause "package already opened" / "missing package product" errors.

## Requirements

- **Xcode 16** or later (Swift 6.2 toolchain)
- **iOS 26** deployment target on device or Simulator
- macOS 15 to host `swift build` from the command line

## Building and running

### In Xcode

```bash
open LyraMusicHost/LyraMusicHost.xcodeproj
```

Select an iOS device or Simulator, ⌘B to build, ⌘R to run. The host project resolves the local Swift package automatically.

### From the CLI

```bash
swift build              # builds LyraMusicKit + LyraMusic shim for macOS host
```

The CLI build is only useful for verifying that `LyraMusicKit` compiles cleanly — the actual app ships from the Xcode project.

## Configuration

### Connecting to a server

The login screen takes a base URL + username + password. Plain `http://` is allowed (`NSAllowsArbitraryLoads` is enabled in Info.plist) so it works against:

- LAN servers (RFC1918 / `.local`)
- Tailscale CGNAT (`100.64.0.0/10`)
- Reverse-proxied / tunnelled servers
- Public IPs without TLS

HTTPS is still preferred whenever your server supports it.

### Last.fm scrobbling

Currently configured via the `LastFmScrobbler.configure(apiKey:secret:sessionKey:)` API only — there is no Settings UI for this yet. Secrets live in the Keychain after first run; a one-time migration moves any older plaintext values out of `UserDefaults`.

### Discovery sources

- **Last.fm** charts use a publishable API key (no user auth needed).
- **MusicBrainz** is contacted with a project-identifying `User-Agent` per their TOS.
- **TheAudioDB** uses the publisher's documented demo key.
- **iTunes Search API** is used for artwork enrichment on chart entries.

## Architecture notes

- `AppModel` (a `@MainActor` `ObservableObject`) owns the active client (`jellyfin` or `navidrome`), library snapshot, playback engine, offline manager, and Last.fm scrobbler.
- `MusicLibraryProviding` is the cross-backend abstraction; `JellyfinMusicClient` and `NavidromeClient` implement it.
- `PlaybackEngine` wraps `AVPlayer` + `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` and feeds Lock Screen / AirPlay metadata.
- `OfflineDownloadManager` writes a structured download tree under `Documents/LyraMusic/Downloads/` with a JSON manifest mapping track IDs to relative paths.
- `LibrarySnapshotStore` persists albums + tracks + playlists + favorites between launches under Application Support.
- `MediaAuthHeaderRegistry` is a small actor that lets artwork / avatar loaders inject per-host `Authorization` headers, so Jellyfin's bearer token never appears in image URLs.

## Security

- **Credentials**: Keychain only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable=false`).
- **Navidrome auth**: per-request salted-token (`t=md5(password+salt)` with a fresh 16-byte salt) — the password is never in the URL.
- **Jellyfin auth**: `Authorization: MediaBrowser Token=...` header on every request, including media and artwork. The token is not appended to URLs.
- **Last.fm secret + session key**: Keychain, with a one-time migration from any older `UserDefaults` entry.
- **Cold launch**: a restored session is probed with `probeAuthStatus()` before the app re-POSTs credentials, so the password is only sent again when the server explicitly rejected the existing session.
- **Offline downloads**: server-supplied artist/album/title strings are sanitized (rejecting `.`, `..`, leading/trailing dots, control chars) and the destination path is bounds-checked against the downloads root before every write.

## Status

Active development. Not all UI affordances are wired yet — notably the **Radio** tab is a layout-only placeholder, and several overflow-menu items ("Create Station", "Pin Song", "View Credits", "Suggest Less") are stubs. The Now Playing share menu uses `ShareLink`, and Favorite / Play Next / Go to Album hooks across the chart and browse-album overflow menus are functional.

## License

No license declared. Treat as all rights reserved unless and until a license file is added.
