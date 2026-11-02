#!/usr/bin/env python3
"""T127 — measure the EP-suffix widening against a real Navidrome library.

Read-only. Touches no app source and writes nothing back to the server.

Produces the two numbers the decision needs:

  A. WRONG COLLAPSES — pairs of albums by the same artist that currently have distinct
     keys and would share one after the widening. These are the invisible failure: two
     real releases becoming one row with nothing on screen to say so. Computed entirely
     from the library, no network beyond fetching it.

  B. DUPLICATES FIXED (upper bound) — owned albums whose title ends in a bare suffix word
     with no dash. These are the only albums the widening can change the key of, so the
     number of duplicates it can possibly resolve cannot exceed this.

Usage:
    python3 t127-suffix-widening-scan.py https://your-navidrome user password
"""
import hashlib, json, re, sys, unicodedata, urllib.parse, urllib.request
from collections import defaultdict

CURRENT = re.compile(
    r"(?i)\s*[-–—]\s*(single|ep|album|deluxe edition|deluxe|expanded edition|remaster(ed)?(\s+\d{4})?)$")
WIDE = re.compile(
    r"(?i)(?:\s*[-–—]\s*|\s+)(single|ep|album|deluxe edition|deluxe|expanded edition|remaster(ed)?(\s+\d{4})?)$")
BARE_ONLY = re.compile(
    r"(?i)\s+(single|ep|album|deluxe edition|deluxe|expanded edition|remaster(ed)?(\s+\d{4})?)$")

def norm_release_key(s):
    s = s.strip()
    if not s:
        return ""
    s = "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")
    return re.sub(r"\s+", " ", s.lower())

def base_key(raw, pattern):
    t = raw.strip()
    if not t:
        return ""
    while True:
        m = pattern.search(t)
        if not m:
            break
        t = t[:m.start()].strip()
    t = re.sub(r"\([^)]*\)", "", t)
    t = re.sub(r"\[[^\]]*\]", "", t)
    t = re.sub(r"\s+", " ", t).strip()
    return norm_release_key(t)

def subsonic(base, user, password, endpoint, extra=""):
    salt = "t127scan"
    token = hashlib.md5((password + salt).encode()).hexdigest()
    q = f"u={urllib.parse.quote(user)}&t={token}&s={salt}&v=1.16.1&c=VellumT127&f=json"
    url = f"{base.rstrip('/')}/rest/{endpoint}.view?{q}{extra}"
    req = urllib.request.Request(url, headers={"User-Agent": "VellumT127/1.0"})
    return json.load(urllib.request.urlopen(req))["subsonic-response"]

def all_albums(base, user, password):
    out, offset = [], 0
    while True:
        r = subsonic(base, user, password, "getAlbumList2",
                     f"&type=alphabeticalByName&size=500&offset={offset}")
        page = r.get("albumList2", {}).get("album", [])
        if not page:
            break
        out += page
        offset += len(page)
        if len(page) < 500:
            break
    return out

def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    base, user, password = sys.argv[1], sys.argv[2], sys.argv[3]
    albums = all_albums(base, user, password)
    print(f"albums scanned: {len(albums)}")

    by_artist = defaultdict(list)
    for a in albums:
        by_artist[(a.get("artist") or "").lower()].append(a.get("name") or "")

    # A. wrong collapses, within an artist (the domain the matcher runs in)
    collisions = []
    for artist, titles in by_artist.items():
        groups = defaultdict(list)
        for t in titles:
            k = base_key(t, WIDE)
            if k:
                groups[k].append(t)
        for _, g in groups.items():
            if len(g) < 2:
                continue
            for i in range(len(g)):
                for j in range(i + 1, len(g)):
                    if base_key(g[i], CURRENT) == base_key(g[j], CURRENT):
                        continue          # already collapsed; not caused by the change
                    if g[i] == g[j]:
                        continue          # same title twice is not two releases
                    collisions.append((artist, g[i], g[j]))

    print(f"\nA. WRONG COLLAPSES (same artist, distinct titles newly merged): {len(collisions)}")
    for artist, x, y in collisions:
        print(f'   [{artist}] "{x}"  ==  "{y}"')

    # B. upper bound on duplicates fixed
    candidates = [(a.get("artist"), a.get("name")) for a in albums
                  if BARE_ONLY.search((a.get("name") or "").strip())]
    print(f"\nB. ALBUMS THE WIDENING CAN AFFECT AT ALL (bare suffix, no dash): {len(candidates)}")
    for artist, name in candidates[:80]:
        print(f'   [{artist}] "{name}"')
    if len(candidates) > 80:
        print(f"   ... and {len(candidates) - 80} more")
    print("\n   Every duplicate the widening could fix is in this list, so it is the ceiling.")
    print("   How many are ACTUAL duplicates depends on whether MusicBrainz carries the same")
    print("   release without the suffix; that is per-artist and needs the artist page to confirm.")

if __name__ == "__main__":
    main()
