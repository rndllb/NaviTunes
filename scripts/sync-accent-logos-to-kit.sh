#!/usr/bin/env bash
# Copy Icon Composer PNGs from LyraMusicHost/AppIcons into LyraMusicKit resources for in-app UI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONS="$ROOT/LyraMusicHost/LyraMusicHost/AppIcons"
DEST="$ROOT/Sources/LyraMusicKit/Resources/AccentLogos"

mkdir -p "$DEST"
cp "$ICONS/AppIcon.icon/Assets/Untitled.png" "$DEST/red.png"
cp "$ICONS/LyraIcon-pink.icon/Assets/pink.png" "$DEST/pink.png"
cp "$ICONS/LyraIcon-orange.icon/Assets/orange.png" "$DEST/orange.png"
cp "$ICONS/LyraIcon-yellow.icon/Assets/yellow.png" "$DEST/yellow.png"
cp "$ICONS/LyraIcon-green.icon/Assets/green.png" "$DEST/green.png"
cp "$ICONS/LyraIcon-teal.icon/Assets/teal.png" "$DEST/teal.png"
cp "$ICONS/LyraIcon-blue.icon/Assets/blue.png" "$DEST/blue.png"
cp "$ICONS/LyraIcon-indigo.icon/Assets/indigo.png" "$DEST/indigo.png"
cp "$ICONS/LyraIcon-purple.icon/Assets/purple.png" "$DEST/purple.png"
cp "$ICONS/LyraIcon-lightgray.icon/Assets/grey.png" "$DEST/lightgray.png"

echo "Synced accent logos → $DEST"
