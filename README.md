# Vellum Music

Vellum Music is an iPhone app that looks and feels like Apple Music, but plays music from your own server.

Sign in with Jellyfin or Navidrome. Browse, search, queue, download, and listen the way you would in Apple Music. The difference is simple: the library is yours. It lives on hardware you control, not on a streaming subscription.

## What it is

If you already run a home music server, Vellum gives you the Apple Music experience on top of it. Same kind of tabs, same kind of player, same kind of library screens. Your files, your server, your rules.

## The Magic Playlist

This is the part that makes Vellum different from a normal server client.

When you add a song or album in Vellum, it goes into a hidden playlist on your server. That playlist is your personal library. It syncs across your devices, keeps track of what you actually added (not just everything sitting on the server), and remembers when you added each item.

On a shared Jellyfin or Navidrome box, your library stays separate from everyone else's. Your phone, your iPad, and your Mac all see the same "my library" list because the server holds it for you.

You never manage that playlist by hand. Vellum creates it, updates it, and keeps it out of your normal playlist list. You just tap Add to Library and it works.

## What you get

### Home

A personalized home screen with shelves like Top Picks, New Releases, Recently Played, Made for You mixes, playlists, and genre rows. Home helps you discover music on the server that you have not added yet.

### New

A browse tab for new releases and artist pages, built from your own server catalog and ranked against your listening. If you connect Lidarr, it also folds in upcoming and wanted releases. Good for finding albums you might want to request or add later.

### Radio

Internet radio stations from Navidrome, plus your own custom stream URLs.

### Library

Albums, songs, playlists, artists, genres, favorites, and downloads. Album and artist pages use big artwork, dynamic colors, and the same kind of layout Apple Music users already know. This is where the app opens by default — you can change that under Settings → Appearance.

### Search

Two modes:

- **Library** searches your personal library: the songs, albums, and playlists you have actually added.
- **Discover** searches the whole server catalog, plus music that is not on your server yet when a request plugin is connected, plus artists you can follow or request.

### Playback

Full queue, shuffle, repeat, play next, lyrics, sleep timer, playback speed, lock screen controls, and a mini player that opens into full Now Playing.

There is also a 10-band equalizer. It needs a local copy of the audio to work, so it applies to downloads and to streams that have been cached. Caching streamed songs is **off** by default; turning the equalizer on enables it for you, or you can flip it yourself under Settings → Sound & Playback.

### Offline

Download albums, playlists, or favorites. Turn on offline mode manually, or let the app switch when you leave Wi-Fi or your home network.

### Widgets

Home screen widgets for recently played music and Made for You mixes.

### Settings

Account, library stats, streaming and download quality, the equalizer, appearance, accent color, app icon, which tab the app opens to, scrobbling to your server, and optional plugins for requesting missing music.

## Request missing music

If something is not on your server yet, Vellum can help you ask for it. Pick one request plugin in Settings → Plugins → Music Requests (only one is active at a time):

- **Lidarr** for full albums
- **Downtify** for individual tracks
- **DroppedNeedle** for album requests through its own service

You can also follow an artist to keep an eye on their discography. Vellum compares what the plugin knows about that artist against what is on your server and can request whatever is missing. Following works without a plugin too — it just becomes a wishlist.

## Servers

Works with:

- **Jellyfin**
- **Navidrome** (Subsonic API)

Credentials stay in the Keychain. HTTP works for local networks. HTTPS is recommended when you can use it.

## Build and run

Requirements:

- Xcode 16 or later
- iOS 26

Open the project:

```bash
open VellumMusicHost/VellumMusicHost.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -workspace VellumMusicHost/VellumMusicHost.xcodeproj/project.xcworkspace \
  -scheme VellumMusicHost -destination 'generic/platform=iOS Simulator' build
```

Open the Xcode project file, not `Package.swift` on its own. Running both at once can confuse Swift Package Manager.

## Author

rndllb

## License

No license file yet. All rights reserved unless stated otherwise.
