"""Stub Lidarr for T068 verification.

Serves the handful of /api/v1 endpoints LidarrAcquisitionPlugin touches, with payloads
shaped like the real ones, and appends every request to a log the test asserts against.

Not a mock of Lidarr's behaviour — only of its wire format, which is what the plugin parses.
"""

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8686
LOG_PATH = sys.argv[2] if len(sys.argv) > 2 else "/tmp/stub_lidarr.log"

log_lock = threading.Lock()


def log(line):
    with log_lock:
        with open(LOG_PATH, "a") as fh:
            fh.write(line + "\n")


def artist_obj(name, mbid):
    return {
        "artistName": name,
        "foreignArtistId": mbid,
        "overview": f"{name} is a stubbed artist.",
        "images": [{"coverType": "poster", "remoteUrl": "https://example.invalid/a.jpg"}],
    }


DANIEL = artist_obj("Daniel Caesar", "e0d0f8d7-1e3a-4e0d-9a9b-000000000001")
POLISH = artist_obj("The Polish Ambassador", "e0d0f8d7-1e3a-4e0d-9a9b-000000000002")


def album_obj(title, artist, mbid, album_type, year, native_id=None):
    row = {
        "title": title,
        "foreignAlbumId": mbid,
        "albumType": album_type,
        "secondaryTypes": [],
        "releaseDate": f"{year}-06-01T00:00:00Z",
        "monitored": False,
        "artist": artist,
        "images": [{"coverType": "cover", "remoteUrl": "https://example.invalid/c.jpg"}],
    }
    if native_id is not None:
        row["id"] = native_id
    return row


# The catalog the stub answers from. "japanese denim" must resolve to the single,
# which is the whole point of the fix.
JDEEJAY = artist_obj("Japanese Deejay", "e0d0f8d7-1e3a-4e0d-9a9b-000000000003")
JDEATH = artist_obj("Japanese Death Machine", "e0d0f8d7-1e3a-4e0d-9a9b-000000000004")
DEPLORER = artist_obj("DJ.Deplorer", "e0d0f8d7-1e3a-4e0d-9a9b-000000000005")
GAGA = artist_obj("Lady GaGa", "e0d0f8d7-1e3a-4e0d-9a9b-000000000006")
ACIDGVRL = artist_obj("Acidgvrl", "e0d0f8d7-1e3a-4e0d-9a9b-000000000007")
DEFTONES = artist_obj("Deftones", "e0d0f8d7-1e3a-4e0d-9a9b-000000000008")
DAFT = artist_obj("Daft Punk", "e0d0f8d7-1e3a-4e0d-9a9b-000000000009")

ALBUMS = [
    album_obj("Japanese Denim", DANIEL, "aaaaaaaa-0000-0000-0000-000000000001", "Single", 2016),
    album_obj("Freudian", DANIEL, "aaaaaaaa-0000-0000-0000-000000000002", "Album", 2017),
    album_obj("Pilot Talk", POLISH, "aaaaaaaa-0000-0000-0000-000000000003", "Album", 2010),
    # The rest of what Ethan's `japanese de` actually returned, so the ranking is exercised
    # against the same shape of candidate list.
    album_obj("Japanese Death Machine", JDEATH, "aaaaaaaa-0000-0000-0000-000000000004", "EP", 2019),
    album_obj("The Fame Monster (Japanese Deluxe Edition)", GAGA, "aaaaaaaa-0000-0000-0000-000000000005", "Album", 2009),
    album_obj("1999 Japanese denim", ACIDGVRL, "aaaaaaaa-0000-0000-0000-000000000006", "Single", 2019),
    # Deftones, for the artist-first criterion. The eponymous album is the stress case: an exact
    # title match competing with an exact artist match.
    album_obj("Deftones", DEFTONES, "aaaaaaaa-0000-0000-0000-000000000007", "Album", 2003),
    album_obj("White Pony", DEFTONES, "aaaaaaaa-0000-0000-0000-000000000008", "Album", 2000),
    album_obj("Discovery", DAFT, "aaaaaaaa-0000-0000-0000-000000000009", "Album", 2001),
]

ARTISTS = [DANIEL, POLISH, JDEEJAY, JDEATH, DEPLORER, GAGA, ACIDGVRL, DEFTONES, DAFT]

# Filled in by the harness for the "already in the library" case: a (title, artist) pair
# that also exists on the Navidrome demo server, so the row must be suppressed.
EXTRA_ALBUMS_PATH = LOG_PATH + ".albums.json"


def extra_albums():
    try:
        with open(EXTRA_ALBUMS_PATH) as fh:
            rows = json.load(fh)
    except (OSError, ValueError):
        return []
    return [
        album_obj(
            r["title"],
            artist_obj(r["artist"], "bbbbbbbb-0000-0000-0000-00000000000%d" % (i + 1)),
            "bbbbbbbb-0000-0000-0000-00000000001%d" % (i + 1),
            r.get("albumType", "Album"),
            r.get("year", 2015),
        )
        for i, r in enumerate(rows)
    ]


def matches(term, *fields):
    """Every token of the term must appear somewhere in the row.

    Substring-of-one-field is not enough: `enqueue` searches "<artist> <album title>", which is
    a substring of neither the title nor the artist on its own.
    """
    tokens = term.lower().split()
    if not tokens:
        return False
    haystack = " ".join((f or "").lower() for f in fields)
    return all(tok in haystack for tok in tokens)


def artist_matches(term, name):
    """Looser than `matches`, to imitate how fuzzy Lidarr's artist lookup really is.

    Ethan's `japanese de` came back with "DJ.Deplorer", which shares only the "de". A strict
    all-tokens rule would never return that, and it is the single most important row to
    reproduce: relevance 0, yet the old flat +1.0 bump put it above the exact match.
    Also matches on a 4-char prefix so a typo like "dafto" still finds "Daft Punk".
    """
    t = term.lower().strip()
    n = (name or "").lower()
    if not t:
        return False
    if any(tok in n for tok in t.split()):
        return True
    return len(t) >= 4 and n.startswith(t[:4])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # stdout noise; we keep our own log

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        q = parse_qs(parsed.query)
        term = (q.get("term") or [""])[0]
        log(f"GET {parsed.path} term={term!r} query={parsed.query}")
        path = parsed.path

        if path == "/api/v1/system/status":
            return self._send({"version": "2.0.0.0", "appName": "Lidarr"})
        if path == "/api/v1/album/lookup":
            pool = ALBUMS + extra_albums()
            hits = [a for a in pool if matches(term, a["title"], a["artist"]["artistName"])]
            return self._send(hits)
        if path == "/api/v1/artist/lookup":
            return self._send([a for a in ARTISTS if artist_matches(term, a["artistName"])])
        if path == "/api/v1/artist":
            return self._send([])  # nothing in the stub library
        if path == "/api/v1/album":
            foreign = (q.get("foreignAlbumId") or [""])[0]
            if foreign in ADDED:
                return self._send([ADDED[foreign]])
            return self._send([])
        if path == "/api/v1/queue":
            return self._send({"records": []})
        if path == "/api/v1/command":
            return self._send([])
        if path == "/api/v1/rootfolder":
            return self._send([{"id": 1, "path": "/music"}])
        if path == "/api/v1/qualityprofile":
            return self._send([{"id": 1, "name": "Any"}])
        if path == "/api/v1/metadataprofile":
            return self._send([{"id": 1, "name": "Standard"}])
        return self._send([])

    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        path = parsed.path

        if path == "/api/v1/album":
            foreign = body.get("foreignAlbumId", "")
            title = body.get("title", "")
            monitored = body.get("monitored")
            log(f"POST /api/v1/album title={title!r} foreignAlbumId={foreign!r} monitored={monitored!r}")
            row = dict(body)
            row["id"] = 4242
            row["monitored"] = True
            ADDED[foreign] = row
            return self._send(row, code=201)
        if path == "/api/v1/command":
            log(f"POST /api/v1/command name={body.get('name')!r} albumIds={body.get('albumIds')!r}")
            return self._send({"id": 99, "name": body.get("name"), "status": "queued"}, code=201)
        log(f"POST {path} body={raw[:200]!r}")
        return self._send({})

    def do_PUT(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        log(f"PUT {parsed.path}")
        try:
            return self._send(json.loads(raw or b"{}"))
        except ValueError:
            return self._send({})


ADDED = {}

if __name__ == "__main__":
    open(LOG_PATH, "w").close()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"stub lidarr on 127.0.0.1:{PORT}, log {LOG_PATH}", flush=True)
    server.serve_forever()
