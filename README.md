# Lyra Music

An iOS music client for self-hosted libraries. Connects to **Jellyfin** and **Navidrome** (Subsonic API), with discovery powered by Last.fm, MusicBrainz, TheAudioDB, and the iTunes Search API.

Built in SwiftUI for iOS 26, with an Apple Music–style layout: Home / New / Radio / Library / Search tabs, a full-screen Now Playing sheet, persistent mini player, and offline downloads.

## Features

- **Self-hosted backends** — sign in to Jellyfin or Navidrome with a single URL + credentials. Test the URL before logging in with the **Test Connection** button (it does a no-auth probe of `/System/Info/Public` or `/rest/ping.view`).
- **Subsonic salted-token auth** for Navidrome — the password never travels in the URL.
- **Streaming + offline** — stream FLAC/MP3/AAC over your server's native APIs, or save tracks/albums for offline playback with a structured `Artist/Album/track.ext` layout. Bitrate tiers (`Original`, `320`, `256`, `128 kbps`) configurable separately for Wi-Fi streaming, cellular streaming, and downloads.
- **Now Playing** — Lock Screen, Control Center, AirPlay route picker, and (on iPhone) the system volume bridge.
- **Discovery** — Last.fm top charts, MusicBrainz new releases (toggleable), TheAudioDB regional trending, and an iTunes-backed artwork resolver for chart entries.
- **Last.fm scrobbling** — once configured, plays scrobble automatically at the spec-correct threshold; secrets are stored in the Keychain.
- **Library tools** — favorites, server playlists (read/write where supported), per-album hero artwork with dynamic gradients, recently added / recently played shelves, 6-band graphic EQ with savable presets.
- **Search** — across library + remote discovery sources, with track-resolution against your local library so chart hits link back to your own copy.
- **Settings tab** — User profile + live server-health pill, library statistics, sync status, media-quality picker (per-network bitrate), appearance (theme + accent + alternate app icon), plugins (MusicBrainz toggle, Downtify companion-app integration), about.
- **Appearance customization** — system / light / dark theme, accent color picker, and 9 alternate app icons (`pink / orange / yellow / green / teal / blue / indigo / purple / lightgray`) plus the default `AppIcon`.
- **Downtify integration** — optional companion app that intercepts download requests so audio files land in a destination of your choice. Configurable URL under Settings → Plugins.

## Project structure

```
Lyra-Music/
├── Package.swift                       # SwiftPM root
├── Sources/
│   ├── LyraMusicKit/                   # All views, models, clients, playback engine
│   │   ├── AppModel.swift              # @Observable / ObservableObject app-wide state
│   │   ├── AppSettingsModels.swift     # Theme, quality, EQ, server-health models
│   │   ├── SettingsView.swift          # Settings tab UI
│   │   ├── SettingsFormDrafts.swift    # Draft/commit pattern for form edits
│   │   ├── LoginView.swift             # Login + Test Connection
│   │   ├── LyraAccentLogo.swift        # Branded logo that follows accent preset
│   │   ├── MusicDesignSystem.swift     # Accent presets, picker grid, design tokens
│   │   ├── JellyfinMusicClient.swift   # Jellyfin backend
│   │   ├── NavidromeClient.swift       # Navidrome / Subsonic backend
│   │   ├── PlaybackEngine.swift        # AVPlayer wrapper + remote command center
│   │   ├── OfflineDownloadManager.swift
│   │   └── …                           # Tabs, browse, search, scrobbler, etc.
│   └── LyraMusic/                      # Tiny SwiftPM executable shim (for `swift build`)
└── LyraMusicHost/
    ├── LyraMusicHost.xcodeproj         # The iOS app target
    └── LyraMusicHost/
        ├── LyraMusicHostApp.swift      # @main entry point
        ├── Info.plist
        └── AppIcons/                   # AppIcon.icon + 9 LyraIcon-<color>.icon variants
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

### Appearance

Settings → Appearance lets the user pick:
- **Theme** — System / Light / Dark (drives SwiftUI `.preferredColorScheme`).
- **Accent color** — A grid of preset accents in `MusicDesignSystem.AppAccentPreset`. The selection feeds into chrome, logo, and now-playing tints.
- **App icon** — System alternate-icon API switches the home-screen icon to one of the color variants in `LyraMusicHost/AppIcons/`.

### Media quality

Settings → Media Quality has three independent pickers:
- **Wi-Fi streaming** — `StreamQualityTier` (`Original` / `320 kbps`).
- **Cellular streaming** — same tiers, defaulted to `320` to be polite on data plans.
- **Downloads** — `DownloadQualityTier` (`Original` / `320` / `256` / `128 kbps`), with per-backend mapping to Jellyfin's `audioBitRate` and Navidrome's `maxBitRate`.

### Downtify

If you run the Downtify companion app, point Lyra at it under Settings → Plugins → Downtify. When configured, a download button appears on track rows that opens a search sheet in Downtify.

### Discovery sources

- **Last.fm** charts use a publishable API key (no user auth needed).
- **MusicBrainz** is contacted with a project-identifying `User-Agent` per their TOS.
- **TheAudioDB** uses the publisher's documented demo key.
- **iTunes Search API** is used for artwork enrichment on chart entries.

## Architecture notes

- `AppModel` (a `@MainActor` `ObservableObject`) owns the active client (`jellyfin` or `navidrome`), library snapshot, playback engine, offline manager, Last.fm scrobbler, and all user-tweakable settings (`themePreference`, `accentPresetId`, `wifiStreamQuality`, `cellularStreamQuality`, `downloadQualityTier`, `musicBrainzEnabled`, EQ state, etc.).
- `MusicLibraryProviding` is the cross-backend abstraction; `JellyfinMusicClient` and `NavidromeClient` implement it. Both expose `probeAuthStatus() -> ServerReachabilityProbe` for cold-launch session reconciliation.
- `PlaybackEngine` wraps `AVPlayer` + `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` and feeds Lock Screen / AirPlay metadata. Bitrate selection respects the active streaming tier and the current network class.
- `OfflineDownloadManager` writes a structured download tree under `Documents/LyraMusic/Downloads/` with a JSON manifest mapping track IDs to relative paths. Filenames are sanitized (control chars / leading dots / traversal tokens / trailing dots stripped) and a containment check verifies the resolved destination is inside the downloads root before every write.
- `LibrarySnapshotStore` persists albums + tracks + playlists + favorites between launches under Application Support.
- `MediaAuthHeaderRegistry` is an actor that lets artwork / avatar / decoder loaders inject per-host `Authorization` headers, so Jellyfin's bearer token never appears in image URLs. `ArtworkURLCache` injects these headers at the cache layer so cached and uncached fetches both authenticate cleanly.
- `SettingsFormDrafts` is the draft-then-commit pattern used by `LoginView` and the server section of `SettingsView` — fields edit a local `ServerConnectionDraft` until the user explicitly pushes it back to `AppModel`.
- `ServerConnectionHealth` is the live reachability state surfaced in the Settings profile pill (`unknown` / `checking` / `noNetwork` / `connected` / `unreachable(reason)`).

## Security

- **Credentials**: Keychain only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable=false`).
- **Navidrome auth**: per-request salted-token (`t=md5(password+salt)` with a fresh 16-byte salt) — the password is never in the URL.
- **Jellyfin auth**: `Authorization: MediaBrowser Token=...` header on every request, including media and artwork. The token is not appended to URLs.
- **Last.fm secret + session key**: Keychain, with a one-time migration from any older `UserDefaults` entry.
- **Cold launch**: a restored session is probed with `probeAuthStatus()` before the app re-POSTs credentials, so the password is only sent again when the server explicitly rejected the existing session.
- **Offline downloads**: server-supplied artist/album/title strings are sanitized (rejecting `.`, `..`, leading/trailing dots, control chars) and the destination path is bounds-checked against the downloads root before every write.

## Status

Active development. The **Radio** tab is intentionally a layout-only placeholder — `RadioTabView` shows decorative station tiles with a footnote calling out that live stations aren't wired to your server yet. A handful of overflow-menu items ("Create Station", "Pin Song", "View Credits", "Suggest Less") remain stubs. The Now Playing share menu uses `ShareLink`, and Favorite / Play Next / Go to Album hooks across the chart and browse-album overflow menus are functional.

## License

No license declared. Treat as all rights reserved unless and until a license file is added.
