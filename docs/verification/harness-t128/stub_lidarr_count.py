"""Counting Lidarr for T128.

Answers the `/api/v1` endpoints `LidarrAcquisitionPlugin.enqueue` touches and counts every
request it receives, so "how many Lidarr calls does Request Discography issue" is a number read
off the server rather than one inferred from the source.

Separate from `scripts/stub-lidarr/stub_lidarr.py` on purpose: that one is a fixture for the
Discover UI tests and is shaped around their catalog. This one has to be faithful on the two
branches the enqueue path takes and has to keep counters, and changing the shared fixture to do
that would risk the tests that depend on it.

Faithfulness that matters for the count:

  * `GET /api/v1/album/{id}` returns the stored row with `monitored: true`, so
    `ensureAlbumMonitored` settles on its first read — the case where Lidarr is NOT mid-refresh.
    The monitor race (#5012) costs up to 4 more GET+PUT pairs per album; `/__counters` reports
    the write loop separately so both ends of that range are visible.
  * `GET /api/v1/command` returns `[]`, i.e. no RefreshArtist in flight, so
    `waitForArtistRefresh` returns after one read.
  * `GET /api/v1/album?foreignAlbumId=` answers 404-equivalent (`[]`) until the album has been
    POSTed, then answers with it — which is what turns the second run down the shorter branch.

Run:  python3 docs/verification/harness-t128/stub_lidarr_count.py [port]
"""

import json
import sys
import threading
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787

lock = threading.Lock()
counts = Counter()
ADDED = {}          # foreignAlbumId -> album row
BY_NATIVE_ID = {}   # native id -> album row
next_id = [4242]


def bump(method, path):
    """Count by method + a path with ids folded out, so `album/4242` and `album/4243` are one row."""
    parts = [p for p in path.split("/") if p]
    folded = "/".join("{id}" if p.isdigit() else p for p in parts)
    with lock:
        counts["total"] += 1
        counts[f"{method} /{folded}"] += 1


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # -- control plane (not counted) -------------------------------------------------

    def _control(self, path):
        if path == "/__counters":
            with lock:
                by_path = {k: v for k, v in counts.items() if k != "total"}
                self._send({"total": counts["total"], "byPath": by_path})
            return True
        if path == "/__reset":
            with lock:
                counts.clear()
            self._send({"ok": True})
            return True
        if path == "/__wipe":
            # Counters AND the stub's library, so the "album new to Lidarr" case really is new.
            with lock:
                counts.clear()
                ADDED.clear()
                BY_NATIVE_ID.clear()
            self._send({"ok": True})
            return True
        return False

    # -- Lidarr ----------------------------------------------------------------------

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if self._control(path):
            return
        bump("GET", path)
        q = parse_qs(parsed.query)

        if path == "/api/v1/system/status":
            return self._send({"version": "2.0.0.0", "appName": "Lidarr"})
        if path == "/api/v1/album/lookup":
            term = (q.get("term") or [""])[0]
            # The app asks by `lidarr:<release-group mbid>`, which real Lidarr resolves exactly.
            if term.startswith("lidarr:"):
                mbid = term.split(":", 1)[1]
                return self._send([{
                    "title": "Release %s" % mbid[:8],
                    "foreignAlbumId": mbid,
                    "albumType": "Album",
                    "secondaryTypes": [],
                    "monitored": False,
                    "artist": {"artistName": "Stub Artist", "foreignArtistId": "artist-" + mbid[:8]},
                }])
            return self._send([])
        if path == "/api/v1/album":
            foreign = (q.get("foreignAlbumId") or [""])[0]
            with lock:
                row = ADDED.get(foreign)
            return self._send([row] if row else [])
        if path.startswith("/api/v1/album/"):
            native = path.rsplit("/", 1)[-1]
            with lock:
                row = BY_NATIVE_ID.get(native)
            return self._send(row or {})
        if path == "/api/v1/command":
            return self._send([])          # nothing running: no RefreshArtist to wait on
        if path == "/api/v1/rootfolder":
            return self._send([{"id": 1, "path": "/music"}])
        if path == "/api/v1/qualityprofile":
            return self._send([{"id": 1, "name": "Any"}])
        if path == "/api/v1/metadataprofile":
            return self._send([{"id": 1, "name": "Standard"}])
        if path == "/api/v1/queue":
            return self._send({"records": []})
        return self._send([])

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        bump("POST", path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}

        if path == "/api/v1/album":
            with lock:
                native = next_id[0]
                next_id[0] += 1
            row = dict(body)
            row["id"] = native
            row["monitored"] = True      # the add stuck; the #5012 race is the other case
            row["artistId"] = 1
            with lock:
                ADDED[body.get("foreignAlbumId", "")] = row
                BY_NATIVE_ID[str(native)] = row
            return self._send(row, code=201)
        if path == "/api/v1/command":
            return self._send({"id": 99, "name": body.get("name"), "status": "queued"}, code=201)
        return self._send({})

    def do_PUT(self):
        parsed = urlparse(self.path)
        bump("PUT", parsed.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        native = parsed.path.rsplit("/", 1)[-1]
        with lock:
            if native in BY_NATIVE_ID:
                BY_NATIVE_ID[native].update(body)
        return self._send(body)


if __name__ == "__main__":
    print("counting lidarr on 127.0.0.1:%d" % PORT, flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
