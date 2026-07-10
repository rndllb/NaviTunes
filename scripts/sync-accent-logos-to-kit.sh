#!/usr/bin/env bash
# Copy Icon Composer PNGs from VellumMusicHost/AppIcons into VellumMusicKit resources for in-app UI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONS="$ROOT/VellumMusicHost/VellumMusicHost/AppIcons"
DEST="$ROOT/Sources/VellumMusicKit/Resources/AccentLogos"

mkdir -p "$DEST"
cp "$ICONS/AppIcon.icon/Assets/Untitled.png" "$DEST/red.png"
cp "$ICONS/VellumIcon-pink.icon/Assets/pink.png" "$DEST/pink.png"
cp "$ICONS/VellumIcon-orange.icon/Assets/orange.png" "$DEST/orange.png"
cp "$ICONS/VellumIcon-yellow.icon/Assets/yellow.png" "$DEST/yellow.png"
cp "$ICONS/VellumIcon-green.icon/Assets/green.png" "$DEST/green.png"
cp "$ICONS/VellumIcon-teal.icon/Assets/teal.png" "$DEST/teal.png"
cp "$ICONS/VellumIcon-blue.icon/Assets/blue.png" "$DEST/blue.png"
cp "$ICONS/VellumIcon-indigo.icon/Assets/indigo.png" "$DEST/indigo.png"
cp "$ICONS/VellumIcon-purple.icon/Assets/purple.png" "$DEST/purple.png"
cp "$ICONS/VellumIcon-lightgray.icon/Assets/grey.png" "$DEST/lightgray.png"

echo "Synced accent logos → $DEST"
