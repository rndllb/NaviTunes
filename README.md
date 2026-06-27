# Lyra Music

An iOS music client for self-hosted libraries. Connects to **Jellyfin** and **Navidrome** (Subsonic API), with discovery and browse metadata from the **iTunes Search API**, plus TheAudioDB enrichment where configured.

Built in SwiftUI for iOS 26, with an Apple Music–style layout: Home / New / Radio / Library / Search tabs, a full-screen Now Playing sheet, persistent mini player, home-screen widgets, and offline downloads.

## Features

### Backends & sign-in

- **Jellyfin** and **Navidrome** (Subsonic API) with a single URL + credentials.
- **Test Connection** on login (`/System/Info/Public` or `/rest/ping.view`).
- **Secondary server URL** with automatic/manual failover.
- **Self-signed HTTPS** trust override for homelab servers.
- **Subsonic salted-token auth** — password never travels in the URL.
- Credentials stored in Keychain only.

### Home

- **Top Picks for You** — taste-ranked **server catalog** albums you have **not** added to your personal library; editorial **250×325** cards (full-width cover + color-bleed band + metadata).
- **New Releases for You** — next taste-ranked server-catalog rows after Top Picks (same eligibility rules; no overlap).
- **New Artists Added** — unique artists from recent server adds, excluding albums already in your library.
- **Recently Played** — local play log merged with server recently-played albums.
- **Tuned In** dynamic mixes — On Repeat, Favorites, Rediscover, New in Your Library (2×2 mosaic cover art).
- **Your Playlists**, **taste-based genre shelves** (4 genres × 9 albums from `listeningTopGenres()`), server **New Releases** fallback when taste shelves are still loading.
- Mixes also appear under **Library → Playlists** (toggle in Settings); mix detail uses the same layout as album detail (no remove-from-playlist).

### New tab

- Personalized browse feed built from the **iTunes Search API** (charts, recent releases, artist discographies) — no MusicBrainz toggle or MusicBrainz browse dependency.
- Taste signals: scrobbles, favorites, followed artists, listening genres (`NewTabPersonalizationEngine`).
- Shelves include **New For You**, **Picked For You**, **New This Week**, **Recent Releases**, artist highlights, and chart rows with acquisition/request affordances.

### Radio

- **Custom stations** — user-added stream URLs (persisted locally).
- **Navidrome internet radio** — server stations when signed in to Navidrome (`getInternetRadioStations`).
- Jellyfin sign-in shows custom stations only (no Subsonic radio API).

### Library

- Albums, Songs, Playlists, Artists, Genres, Favorites, Downloaded.
- **Personal library** (“My Library”) synced via a server-side magic playlist (`__lyra_*`) with accurate per-item “Recently Added (yours)” dates.
- Configurable sections, pins, server playlist CRUD where supported.
- Per-album hero artwork with dynamic gradients; **tappable artist names** navigate to the artist page (except “Various Artists”).
- **Kill mode** for playlist editing (batch remove + commit).

### Discovery & search

- **Discover** tab — server catalog search plus **iTunes artist matches** for artists not on your server (opens `ArtistPageView`).
- **Library search** — personal library only (songs in your magic playlist / indexed discovery cache).
- **Acquisition plugins** — request missing music through Lidarr (a music collection manager); optional auto-add to personal library after server scan. Request any artist via Discover search or Settings → Following.
- **Artist following** — follow artists from the artist page; Settings → Plugins → Following keeps discographies complete via **iTunes discography** + the active acquisition plugin (wishlist when no album-level plugin is configured).
- Off-server album detail uses **iTunes catalog tracklists** (`ITunesTracklistClient`) for “complete album” / request rows.

### Playback

- Full queue, shuffle, repeat, play next, add to queue, reorder in Now Playing.
- Mini player with cover **zoom transition** into full-screen Now Playing.
- Persisted queue restore, playback speed, sleep timer, skip-interval buttons.
- Lock-screen remote: skip track vs skip interval modes.
- **Play more like this**, play artist (configurable: top songs / shuffle album / full discography), go to artist/album/playlist.
- **Add to playlist** from Now Playing uses a **UIKit sheet over the player** so the zoom transition is not broken by SwiftUI `.sheet`.
- **10-band graphic equalizer** — `AVAudioEngine` + `AVAudioUnitEQ` on local audio (downloads + stream cache); streams start immediately and auto-switch to EQ once cached locally.
- **Stream disk cache** — optional replay cache for progressive streams; EQ mode also warms cache in the background.
- **Synced lyrics** (Navidrome structured LRC / Jellyfin lyrics API) with Apple Music–style focus scroll; plain-text lyrics shown unsynced.
- **Now Playing artist line** — adaptive light/dark text from artwork backdrop luminance (readable on white covers).
- **My Listening** analytics — streaks, heatmap, top artists/tracks from completed server scrobbles.
- Stale track ID recovery after server rescans (queue + downloads + personal library).

### Offline & downloads

- Stream or save tracks/albums/playlists/favorites.
- Structured `Artist/Album/track.ext` download layout with manifest.
- Wi‑Fi-only downloads, storage cap, cache browser, download queue UI.
- Manual **offline mode** + **auto-offline** (non-Wi‑Fi or away from home SSID).
- Auto-download on favorite.
- Separate **Wi‑Fi / cellular streaming** bitrate & format and **download** quality tiers.

### Widgets

Home-screen widgets (app group snapshot from the main app):

- **Recently Played** — small through extra large; play current/recent track.
- **Top Picks / Tuned In** — recommendations from `homeMixes` with per-mix play actions.

### Settings

iOS Settings–style **hub** (`SettingsView`) with dedicated subpages (`SettingsSections.swift`):

- **Account** — profile, server connection, sign out.
- **Library** — **Your Library** (personal magic-playlist counts) vs **Server Catalog** (full-server totals). Navidrome catalog stats use paginated `getAlbumList2` + `x-total-count`.
- **Sync** — library membership sync status.
- **Library & Data** — show mixes in Playlists, scrobble browser/exclusions, **My Listening**, client backup/restore (scrobbles, exclusions, prefs — not credentials or server library), Navidrome share links, library scan controls.
- **Offline** / **Downloads** — offline mode, auto-offline, download queue and storage browser.
- **Sound & Playback** — Wi‑Fi/cellular streaming quality, download quality, stream cache toggle, **equalizer** (presets + per-band sliders), player controls, artist play mode.
- **Appearance** — theme, song list size, backdrop toggles, **accent color** (presets + custom hex), **app icon** (independent from accent).
- **Plugins** — **Music Requests** (acquisition plugin picker + activity), **Following** (subscription management).
- **About** — app info.
- **Server health** pill on the hub; library stats refresh on Settings appear.

### Integrations

- **Server scrobbling** — now playing + completed plays with pending queue and retry.
- **Artist following** — iTunes discography diff + acquisition enqueue (`MusicSubscriptionEngine`); works as a wishlist without a download plugin.
- Transient toasts for queue/library confirmations.
- Navidrome profile picture via magic-playlist cover upload.
- Navidrome **share links** from album/track/playlist context menus.

## Project structure

```
Lyra Music IOS/
├── Package.swift                       # SwiftPM root
├── Sources/
│   └── LyraMusicKit/                   # All views, models, clients, playback engine
│       ├── AppModel.swift              # App-wide state
│       ├── JellyfinMusicClient.swift
│       ├── NavidromeClient.swift
│       ├── ITunesArtistClient.swift    # Artist search + discography (New/Discover/Following)
│       ├── ITunesTracklistClient.swift # Off-server album tracklists
│       ├── ITunesNewReleasesClient.swift
│       ├── PlaybackEngine.swift
│       ├── HomeView.swift              # Taste-based Home shelves + editorial Top Picks cards
│       ├── NewTabPersonalizationEngine.swift
│       ├── OverPlayerSheetPresenter.swift
│       └── …
├── LyraMusicHost/
│   ├── LyraMusicHost.xcodeproj
│   ├── LyraMusicHost/                  # iOS app target
│   └── LyraWidgets/                    # Widget extension
└── Sources/LyraWidgetSupport/          # Shared widget models + snapshot writer
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

### Acquisition plugins (requesting music)

Settings → Plugins → **Music Requests**. Requesting missing music goes through a single swappable **acquisition plugin** — one is active at a time:

| Plugin | Granularity | Track search | Config |
|---|---|---|---|
| **Lidarr** (music collection manager) | Album | No | Server URL + API key |

Every UI request builds one `AcquisitionRequest` and calls `app.requestAcquisition(_:)`. Lidarr still resolves releases via MusicBrainz internally; Lyra’s browse/artist surfaces use **iTunes** for metadata.

### Discovery / browse metadata

- **iTunes Search API** — New tab feed, off-server artist pages, Discover artist matches, album tracklists for request flows.
- **TheAudioDB** (demo key) — artist enrichment (top tracks, similar artists) where configured.

**Removed from the app:** in-app MusicBrainz browse (`MusicBrainzArtistClient`, `MusicBrainzTracklistClient`, Cover Art Archive artwork helper, Settings → Plugins MusicBrainz toggle).

## Architecture (short)

- `AppModel` — active client, library snapshot, playback, offline manager, settings, Home taste shelves (`homeTopPickAlbums`, `homeNewReleaseAlbums`).
- `MusicLibraryProviding` — cross-backend abstraction (`JellyfinMusicClient`, `NavidromeClient`).
- `NewTabPersonalizationEngine` — taste ranking for New tab and Home discovery shelves.
- `PlaybackEngine` — `AVPlayer` (default) or `EqualizedAudioEnginePlayer` (EQ on local files) + Now Playing + remote commands.
- Personal library — magic playlist + JSON membership payload on server.

See **CLAUDE.md** for backend capability differences, library semantics, lyrics parsing, and contributor conventions.

## Known limitations

| Area | Limitation |
|------|------------|
| **Subsonic clients** | Navidrome backend speaks Subsonic/OpenSubsonic; not marketed as a generic “any Subsonic server” client (some features use Navidrome-native `/api/`). |
| **Some overflow rows** | A few chart-preview / menu stubs remain. |
| **Server catalog vs personal library** | Home Top Picks / New Releases / genre shelves show **server catalog you don’t own**; Library “Recently Added” is your personal magic playlist. |
| **Tuned In mixes** | Require ≥ 3 tracks per mix; On Repeat / Rediscover use **completed server scrobbles**. |
| **Lyrics** | Plain-text / unsynced sources do not auto-scroll. |
| **Auto-offline** | Restricts Discovery search to downloaded content; does not fully gate Home/Library streaming. |
| **Jellyfin radio** | No server internet-radio API — custom stations only. |
| **Navidrome library stats** | Song totals sum album `trackCount` — may differ slightly from true track count. |
| **Equalizer on streams** | EQ requires a local file; first uncached play uses AVPlayer until cache handoff. |
| **Search tab** | Detached search tab button vs tab-bar scroll-collapse are mutually exclusive on current iOS (see ISSUES.md). |

## Security

- Keychain credentials (`AfterFirstUnlockThisDeviceOnly`, not iCloud-synced).
- Jellyfin: bearer token in headers, not URLs.
- Navidrome: salted token per request.
- Cold launch probes existing session before re-sending password.
- Download paths sanitized and containment-checked.

## License

No license declared. Treat as all rights reserved unless a license file is added.
