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

A browse tab for charts, new releases, and artist pages. Good for finding albums you might want to request or add later.

### Radio

Internet radio stations from Navidrome, plus your own custom stream URLs.

### Library

Albums, songs, playlists, artists, genres, favorites, and downloads. Album and artist pages use big artwork, dynamic colors, and the same kind of layout Apple Music users already know.

### Search

Two modes:

- **Discover** searches your server, Apple Music catalog results for missing music, and artists you can follow or request.
- **Library** searches everything on the server, not just what is in your personal library.

### Playback

Full queue, shuffle, repeat, play next, lyrics, sleep timer, playback speed, lock screen controls, and a mini player that opens into full Now Playing. There is a 10-band equalizer for downloads and cached streams.

### Offline

Download albums, playlists, or favorites. Turn on offline mode manually, or let the app switch when you leave Wi-Fi or your home network.

### Widgets

Home screen widgets for recently played music and Made for You mixes.

### Settings

Account, library stats, playback quality, downloads, appearance, accent color, app icon, scrobbling, and optional plugins for requesting missing music.

## Request missing music

If something is not on your server yet, Vellum can help you ask for it. Connect one request plugin in Settings:

- **Lidarr** for full albums
- **Downtify** for individual tracks
- **DroppedNeedle** for album requests through its own service

You can also follow artists and keep an eye on their discography from the app.

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

Randall Brown

## License

No license file yet. All rights reserved unless stated otherwise.
