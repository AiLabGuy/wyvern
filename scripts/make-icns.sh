#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

# Builds build/AppIcon.icns from the icon renders in assets/icon (CC-BY-4.0, see ASSETS.md).
# 16 and 32 px slots use the small master renders; larger slots use the full master.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "make-icns.sh requires macOS (Darwin) because it uses iconutil. This host is $(uname -s)." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/assets/icon"
SET="$ROOT/build/AppIcon.iconset"
rm -rf "$SET"
mkdir -p "$SET"

cp "$SRC/wyvern-icon-16.png" "$SET/icon_16x16.png"
cp "$SRC/wyvern-icon-32.png" "$SET/icon_16x16@2x.png"
cp "$SRC/wyvern-icon-32.png" "$SET/icon_32x32.png"
cp "$SRC/wyvern-icon-64.png" "$SET/icon_32x32@2x.png"
cp "$SRC/wyvern-icon-128.png" "$SET/icon_128x128.png"
cp "$SRC/wyvern-icon-256.png" "$SET/icon_128x128@2x.png"
cp "$SRC/wyvern-icon-256.png" "$SET/icon_256x256.png"
cp "$SRC/wyvern-icon-512.png" "$SET/icon_256x256@2x.png"
cp "$SRC/wyvern-icon-512.png" "$SET/icon_512x512.png"
cp "$SRC/wyvern-icon-1024.png" "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o "$ROOT/build/AppIcon.icns"
echo "Wrote build/AppIcon.icns"
