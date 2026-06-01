# Lyra Music

An iOS music client for self-hosted libraries. Connects to **Jellyfin** and **Navidrome** (Subsonic API), with discovery powered by MusicBrainz, TheAudioDB, and the iTunes Search API.

Built in SwiftUI for iOS 26, with an Apple Music–style layout: Home / New / Radio / Library / Search tabs, a full-screen Now Playing sheet, persistent mini player, and offline downloads.

## Features

### Backends & sign-in

- **Jellyfin** and **Navidrome** (Subsonic API) with a single URL + credentials.
- **Test Connection** on login (`/System/Info/Public` or `/rest/ping.view`).
- **Secondary server URL** with automatic/manual failover.
- **Self-signed HTTPS** trust override for homelab servers.
- **Subsonic salted-token auth** — password never travels in the URL.
- Credentials stored in Keychain only.

### Home

- **Top Picks**, **New Artists Added**, **Recently Played** (local + server albums).
- **Tuned In** dynamic mixes — On Repeat, Favorites, Rediscover, New in Your Library (2×2 mosaic cover art).
- **Your Playlists**, genre shelves, **New Releases** (server catalog).
- Mixes also appear under **Library → Playlists** (toggle in Settings); mix detail uses the same layout as album detail (no remove-from-playlist).

### Library

- Albums, Songs, Playlists, Artists, Genres, Favorites, Downloaded.
- **Personal library** (“My Library”) synced via a server-side magic playlist (`__lyra_*`) with accurate per-item “Recently Added (yours)” dates.
- Configurable sections, pins, server playlist CRUD where supported.
- Per-album hero artwork with dynamic gradients.
- **Kill mode** for playlist editing (batch remove + commit).

### Discovery & search

- **Discovery** tab — server catalog search (MusicBrainz new releases, TheAudioDB trending, iTunes artwork enrichment).
- **Library search** — personal library only (songs in your magic playlist / indexed discovery cache).
- **Downtify** integration — request missing tracks via companion app; optional auto-add to personal library after server scan.

### Playback

- Full queue, shuffle, repeat, play next, add to queue, reorder in Now Playing.
- Mini player, persisted queue restore, playback speed, sleep timer, skip-interval buttons.
- Lock-screen remote: skip track vs skip interval modes.
- **Play more like this**, play artist (configurable: top songs / shuffle album / full discography), go to artist/album/playlist.
- **Synced lyrics** (Navidrome structured LRC / Jellyfin lyrics API) with Apple Music–style focus scroll; plain-text lyrics shown unsynced.
- **My Listening** analytics — streaks, heatmap, top artists/tracks from completed server scrobbles.
- Stale track ID recovery after server rescans (queue + downloads + personal library).

### Offline & downloads

- Stream or save tracks/albums/playlists/favorites.
- Structured `Artist/Album/track.ext` download layout with manifest.
- Wi‑Fi-only downloads, storage cap, cache browser, download queue UI.
- Manual **offline mode** + **auto-offline** (non-Wi‑Fi or away from home SSID).
- Auto-download on favorite.
- Separate **Wi‑Fi / cellular streaming** bitrate & format and **download** quality tiers.

### Settings

- **Sound & Playback** — streaming quality, download quality, player controls, album metadata refresh threshold, artist play mode.
- **Library & Data** — show mixes in Playlists, scrobble browser/exclusions, **My Listening**, client backup/restore (scrobbles, exclusions, prefs — not credentials or server library), Navidrome share links (create from item menus, list/delete in Settings), library scan controls.
- **Appearance** — system/light/dark theme, accent color, 9 alternate app icons.
- **Server health** pill, **library statistics** (Jellyfin: accurate totals; Navidrome: approximate from album index), sync status.
- **6-band graphic EQ** with savable presets.

### Integrations

- **Server scrobbling** — now playing + completed plays with pending queue and retry.
- **CarPlay** (`CarPlayCoordinator`).
- Transient toasts for queue/library confirmations.
- Navidrome profile picture via magic-playlist cover upload.

## Project structure

```
Lyra Music IOS/
├── Package.swift                       # SwiftPM root
├── Sources/
│   └── LyraMusicKit/                   # All views, models, clients, playback engine
│       ├── AppModel.swift              # App-wide state
│       ├── JellyfinMusicClient.swift
│       ├── NavidromeClient.swift
│       ├── PlaybackEngine.swift
│       ├── HomeMixBuilder.swift        # Tuned In mixes
│       ├── OfflineDownloadManager.swift
│       └── …
└── LyraMusicHost/
    ├── LyraMusicHost.xcodeproj         # iOS app target
    └── LyraMusicHost/
        ├── LyraMusicHostApp.swift
        └── AppIcons/
```

Open **`LyraMusicHost/LyraMusicHost.xcodeproj`** only — opening `Package.swift` in a second Xcode window can cause package resolution conflicts.

## Requirements

- **Xcode 16** or later (Swift 6.2 toolchain)
- **iOS 26** deployment target
- macOS 15+ for CLI `swift build`

## Building and running

```bash
open LyraMusicHost/LyraMusicHost.xcodeproj
```

Or from the CLI (compile check only):

```bash
xcodebuild -workspace LyraMusicHost/LyraMusicHost.xcodeproj/project.xcworkspace \
  -scheme LyraMusicHost -destination 'generic/platform=iOS Simulator' build
```

## Configuration

### Server URL

Plain `http://` is allowed for LAN, Tailscale, and homelab setups (`NSAllowsArbitraryLoads` in Info.plist). HTTPS is preferred when available.

### Media quality

Settings → Sound & Playback: independent Wi‑Fi streaming, cellular streaming, and download quality/format pickers.

### Downtify

Settings → Plugins → Downtify URL. When configured, download/search actions appear on tracks missing from your library.

### Discovery sources

- MusicBrainz (project User-Agent per TOS)
- TheAudioDB (demo key)
- iTunes Search API (chart artwork)

## Architecture (short)

- `AppModel` — active client, library snapshot, playback, offline manager, settings.
- `MusicLibraryProviding` — cross-backend abstraction (`JellyfinMusicClient`, `NavidromeClient`).
- `PlaybackEngine` — `AVPlayer` + Now Playing + remote commands.
- `OfflineDownloadManager` — downloads under `Documents/LyraMusic/Downloads/`.
- `LibrarySnapshotStore` — persisted albums/tracks/playlists between launches.
- Personal library — magic playlist + JSON membership payload on server.

See **CLAUDE.md** for backend capability differences, library semantics, lyrics parsing, and contributor conventions.

## Known limitations

| Area | Limitation |
|------|------------|
| **Radio tab** | Layout placeholder — no live stations wired to your server yet. |
| **Some overflow items** | A few menu rows are still stubs (e.g. Start Collaboration, Move to Folder, some chart preview actions). |
| **Server catalog vs personal library** | Home “New Releases” / Top Picks use server catalog; Library “Recently Added” uses your personal magic playlist. |
| **Tuned In mixes** | Require ≥ 3 tracks per mix; On Repeat / Rediscover use **completed server scrobbles**, not local play history alone. |
| **Lyrics** | Plain-text / unsynced sources do not auto-scroll. Sync quality depends on source LRC or structured timestamps. |
| **Auto-offline** | Restricts Discovery search to downloaded content; does not fully gate Home/Library streaming. SSID detection needs location permission on iOS. |
| **Client backup** | Exports local scrobbles, exclusions, playback prefs — not credentials, audio files, or server magic-playlist state. |
| **Jellyfin “similar tracks”** | Artist search shuffle, not true similarity API. |
| **Navidrome library stats** | Settings → Library counts are approximate (album index + summed `trackCount`; large libraries may hit the fetch cap). |
| **Navidrome share from charts** | Create Share Link needs a server track/album/playlist id — chart preview rows without one skip the action. |

## Security

- Keychain credentials (`AfterFirstUnlockThisDeviceOnly`, not iCloud-synced).
- Jellyfin: bearer token in headers, not URLs.
- Navidrome: salted token per request.
- Cold launch probes existing session before re-sending password.
- Download paths sanitized and containment-checked.

## License

No license declared. Treat as all rights reserved unless a license file is added.
