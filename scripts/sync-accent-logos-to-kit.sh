#!/usr/bin/env bash
# Copy Icon Composer PNGs from NaviTunesHost/AppIcons into NaviTunesKit resources for in-app UI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONS="$ROOT/NaviTunesHost/NaviTunesHost/AppIcons"
DEST="$ROOT/Sources/NaviTunesKit/Resources/AccentLogos"

mkdir -p "$DEST"
cp "$ICONS/AppIcon.icon/Assets/Untitled.png" "$DEST/red.png"
cp "$ICONS/NaviTunesIcon-pink.icon/Assets/pink.png" "$DEST/pink.png"
cp "$ICONS/NaviTunesIcon-orange.icon/Assets/orange.png" "$DEST/orange.png"
cp "$ICONS/NaviTunesIcon-yellow.icon/Assets/yellow.png" "$DEST/yellow.png"
cp "$ICONS/NaviTunesIcon-green.icon/Assets/green.png" "$DEST/green.png"
cp "$ICONS/NaviTunesIcon-teal.icon/Assets/teal.png" "$DEST/teal.png"
cp "$ICONS/NaviTunesIcon-blue.icon/Assets/blue.png" "$DEST/blue.png"
cp "$ICONS/NaviTunesIcon-indigo.icon/Assets/indigo.png" "$DEST/indigo.png"
cp "$ICONS/NaviTunesIcon-purple.icon/Assets/purple.png" "$DEST/purple.png"
cp "$ICONS/NaviTunesIcon-lightgray.icon/Assets/grey.png" "$DEST/lightgray.png"

echo "Synced accent logos → $DEST"
