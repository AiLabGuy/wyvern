#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "make-dmg.sh requires macOS (Darwin). This host is $(uname -s). Refusing to create a disk image." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
. "$ROOT/scripts/load-product-env.sh"

app_path="$ROOT/build/${APP_BUNDLE}"
if [[ ! -d "$app_path" ]]; then
  echo "Missing build/${APP_BUNDLE}. Run scripts/build-app.sh first." >&2
  exit 1
fi

stage="$(mktemp -d)"
cleanup() {
  rm -rf "$stage"
}
trap cleanup EXIT

cp -R "$app_path" "$stage/${APP_BUNDLE}"
ln -s /Applications "$stage/Applications"

mkdir -p "$ROOT/build"
dmg_path="$ROOT/build/${DMG_BASENAME}-${VERSION}.dmg"
hdiutil create \
  -volname "${PRODUCT_NAME}" \
  -srcfolder "$stage" \
  -ov \
  -format UDZO \
  "$dmg_path"

hdiutil verify "$dmg_path"
digest="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
dmg_name="${DMG_BASENAME}-${VERSION}.dmg"
sha_line="$(printf '%s  %s' "$digest" "$dmg_name")"
printf '%s\n' "$sha_line" > "${dmg_path}.sha256"
bytes="$(stat -f '%z' "$dmg_path")"
echo "DMG size: ${bytes} bytes"
printf '%s\n' "$sha_line"
echo "Wrote build/${dmg_name} and build/${dmg_name}.sha256"
