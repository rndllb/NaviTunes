# Stub Lidarr

A stand-in Lidarr for the Discover-search UI tests
(`VellumMusicHost/VellumMusicUITests/DiscoverAlbumSearch.swift`).

It exists because those tests need a *known* acquisition catalog. Pointing them at a real Lidarr
would make them depend on somebody's private server, its contents, and its credentials — and the
tests assert on exact rows and their order.

The stub serves Lidarr's **wire format**, not its behaviour. `LidarrAcquisitionPlugin` only ever
parses JSON, so that is all that has to be faithful.

## Running it

```sh
python3 scripts/stub-lidarr/stub_lidarr.py            # port 8686, log /tmp/stub_lidarr.log
python3 scripts/stub-lidarr/stub_lidarr.py 9999 /tmp/my.log
```

Then run the tests. Standard library only — no venv, no packages.

If the stub is **not** running the tests **skip**, they do not fail (`StubLidarr.skipUnlessRunning`),
so a plain `xcodebuild test` stays green without the harness.

## How the app is pointed at it

Two things make this work with no changes to the app and no writes to your settings:

- The iOS Simulator shares the host's network stack, so `http://127.0.0.1:8686` inside the app
  reaches the stub running on the Mac.
- `AcquisitionConfigStore` reads plain `UserDefaults`, and XCUITest `-key value` launch arguments
  land in `NSArgumentDomain`, which `UserDefaults.standard` consults first. So
  `-acquisition.lidarr.baseURL http://127.0.0.1:8686` configures the plugin **for that launch
  only** — nothing is persisted and your own Lidarr settings are untouched.

## Assertions on what Lidarr received

Every request is appended to the log file. The simulator cannot read the host's filesystem, so
tests that care about what was *sent* (the enqueue sequence: `POST /api/v1/album` with
`monitored: true`, then `POST /api/v1/command` `AlbumSearch`) are checked by reading that log on
the host after the run, not from inside the test.

## Gotcha worth keeping

`LidarrAcquisitionPlugin.enqueue` looks up `"<artist> <album title>"` — a string that is a
substring of neither the artist nor the title on its own. The matcher here is therefore
token-based. A naive substring matcher returns nothing for the enqueue lookup and the request
silently fails to resolve.
