#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-app.sh requires macOS (Darwin). This host is $(uname -s). Refusing to build." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
. "$ROOT/scripts/load-product-env.sh"

# Update source (docs/UPDATES.md). Nothing here is read from git remotes or the network.
# A release build takes UPDATE_FEED_URL only from config/product.env or the environment, and
# accepts it only empty or as a public https URL with a plain path.
# These values are substituted into Info.plist with sed; refuse anything that is not plain text.
unsafe_re="[|&<>\"'\\[:space:]]"
for value in "${UPDATE_FEED_URL}" "${UPDATE_PUBLIC_KEY}" "${UPDATE_DEV_SOURCE}"; do
  if [[ "$value" =~ $unsafe_re ]]; then
    echo "UPDATE_FEED_URL, UPDATE_PUBLIC_KEY, and UPDATE_DEV_SOURCE must not contain spaces or | & < > \" ' \\" >&2
    exit 1
  fi
done
# Placeholders (GITHUB_OWNER/GITHUB_REPO, or a release key not generated yet): build without a
# built-in source rather than ship an unusable one. People can still set a source in Settings.
if [[ "${UPDATE_FEED_URL}" == *GITHUB_OWNER* || "${UPDATE_FEED_URL}" == *GITHUB_REPO* || "${UPDATE_PUBLIC_KEY}" == *PLACEHOLDER* ]]; then
  echo "::warning::update feed URL or public key is still a placeholder; building with no built-in update source"
  UPDATE_FEED_URL=""
  UPDATE_PUBLIC_KEY=""
fi
swift_flags=()
if [[ "${WYVERN_DEV_UPDATER:-}" == "1" ]]; then
  echo "::warning::WYVERN_DEV_UPDATER=1: dev updater build (private-network http allowed). Do not ship it."
  swift_flags=(-Xswiftc -DWYVERN_DEV_UPDATER)
else
  UPDATE_DEV_SOURCE=""
  if [[ -n "${UPDATE_FEED_URL}" ]]; then
    feed_re='^https://([A-Za-z0-9.-]+)(:[0-9]+)?(/[A-Za-z0-9._~%+/-]*)?$'
    if [[ ! "${UPDATE_FEED_URL}" =~ $feed_re ]]; then
      echo "UPDATE_FEED_URL must be https://host[:port]/path with no user info, query, or fragment" >&2
      exit 1
    fi
    feed_host="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    private_re='^(10|127)\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^169\.254\.|^localhost$|\.(local|lan|internal|home\.arpa)$'
    if [[ "$feed_host" =~ $private_re ]]; then
      echo "UPDATE_FEED_URL must not name a private or local host in a release build" >&2
      exit 1
    fi
  fi
fi

bash "$ROOT/scripts/gen-third-party.sh"
bash "$ROOT/scripts/make-icns.sh"

bin_path=""
if swift build -c release ${swift_flags[@]+"${swift_flags[@]}"} --arch arm64 --arch x86_64; then
  bin_dir="$(swift build -c release ${swift_flags[@]+"${swift_flags[@]}"} --arch arm64 --arch x86_64 --show-bin-path)"
  candidate="${bin_dir}/${SWIFT_PRODUCT}"
  if lipo "$candidate" -verify_arch arm64 && lipo "$candidate" -verify_arch x86_64; then
    bin_path="$candidate"
  else
    echo "Combined arch product is not universal. Building each architecture and joining with lipo." >&2
  fi
else
  echo "Universal swift build failed. Building each architecture and joining with lipo." >&2
fi

if [[ -z "$bin_path" ]]; then
  swift build -c release ${swift_flags[@]+"${swift_flags[@]}"} --arch arm64
  arm_dir="$(swift build -c release ${swift_flags[@]+"${swift_flags[@]}"} --arch arm64 --show-bin-path)"
  mkdir -p "$ROOT/build"
  if swift build -c release ${swift_flags[@]+"${swift_flags[@]}"} --arch x86_64; then
    x64_dir="$(swift build -c release ${swift_flags[@]+"${swift_flags[@]}"} --arch x86_64 --show-bin-path)"
    lipo -create "${arm_dir}/${SWIFT_PRODUCT}" "${x64_dir}/${SWIFT_PRODUCT}" -output "$ROOT/build/${SWIFT_PRODUCT}.universal"
    bin_path="$ROOT/build/${SWIFT_PRODUCT}.universal"
  else
    echo "::warning::x86_64 build failed; falling back to arm64-only. CI will still produce a DMG."
    bin_path="${arm_dir}/${SWIFT_PRODUCT}"
  fi
fi

app_path="$ROOT/build/${APP_BUNDLE}"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path" "$app_path/Contents/MacOS/${EXECUTABLE_NAME}"
chmod 755 "$app_path/Contents/MacOS/${EXECUTABLE_NAME}"
if [[ -z "${WYVERN_GIT_COMMIT:-}" ]]; then
  WYVERN_GIT_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
fi
BUILD_NUMBER="${BUILD_NUMBER:-1}"
export WYVERN_GIT_COMMIT UPDATE_FEED_URL UPDATE_DEV_SOURCE BUILD_NUMBER
generate_info_plist "$app_path/Contents/Info.plist"
if [[ "${WYVERN_DEV_UPDATER:-}" == "1" ]]; then
  # URLSession is subject to ATS. Dev builds fetch the LAN feed over http.
  python3 - "$app_path/Contents/Info.plist" "${DEV_FEED_HOST:-}" <<'PY'
import plistlib
import sys

path = sys.argv[1]
dev_host = sys.argv[2]
with open(path, "rb") as handle:
    info = plistlib.load(handle)
ats = info.setdefault("NSAppTransportSecurity", {})
ats["NSAllowsLocalNetworking"] = True
if dev_host:
    domains = ats.setdefault("NSExceptionDomains", {})
    domains[dev_host] = {
        "NSExceptionAllowsInsecureHTTPLoads": True,
        "NSIncludesSubdomains": True,
    }
with open(path, "wb") as handle:
    plistlib.dump(info, handle)
PY
fi
bash "$ROOT/scripts/gen-third-party.sh"
cp "$ROOT/build/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY_LICENSES.md" "$app_path/Contents/Resources/"

echo "Final binary:"
lipo -info "$app_path/Contents/MacOS/${EXECUTABLE_NAME}"

xattr -cr "$app_path"
codesign --force --deep -s - --options runtime --entitlements Wyvern.entitlements "$app_path"
# Ad-hoc signatures get a new cdhash every build, so macOS privacy (TCC) grants such as the
# microphone stop matching after each update ("Failed to match existing code requirement").
# Re-sign the outer bundle with a designated requirement on the bundle id so grants survive updates.
codesign --force -s - --options runtime --entitlements Wyvern.entitlements \
  -r="designated => identifier \"${BUNDLE_ID}\"" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Built ${app_path}"
