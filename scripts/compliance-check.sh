#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

status=0
forbidden_file=".compliance/forbidden.txt"
allow_file=".compliance/allowlist.txt"
patterns=()
extra_patterns=()
allow=()

load_lists() {
  patterns=()
  allow=()
  extra_patterns=()
  if [[ ! -f "$forbidden_file" ]]; then
    echo "missing ${forbidden_file}" >&2
    exit 1
  fi
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    patterns+=("$line")
  done < "$forbidden_file"

  # Owner-identity patterns arrive only through the environment. Never print them.
  local extra_value extra_trim extra_norm
  extra_value="${FORBIDDEN_EXTRA:-}"
  extra_trim="${extra_value#"${extra_value%%[![:space:]]*}"}"
  extra_trim="${extra_trim%"${extra_trim##*[![:space:]]}"}"
  if [[ -z "$extra_trim" ]]; then
    echo "::warning::FORBIDDEN_EXTRA secret is not set; owner-identity scan skipped"
  else
    extra_norm="${extra_value//$'\r'/}"
    extra_norm="${extra_norm//,/$'\n'}"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      extra_patterns+=("$line")
    done <<< "$extra_norm"
  fi

  if [[ -f "$allow_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      [[ "$line" == \#* ]] && continue
      allow+=("$line")
    done < "$allow_file"
  fi
}

# path:pattern:substring exempts only that named pattern when the line contains substring.
# FORBIDDEN_EXTRA is never passed here.
line_exempts() {
  local rel="$1"
  local text="$2"
  local pat="$3"
  local entry file_part rest named sub
  if [[ ${#allow[@]} -eq 0 ]]; then
    return 1
  fi
  for entry in "${allow[@]}"; do
    file_part="${entry%%:*}"
    rest="${entry#*:}"
    named="${rest%%:*}"
    if [[ "$rest" == "$named" ]]; then
      continue
    fi
    sub="${rest#*:}"
    if [[ -z "$named" || -z "$sub" ]]; then
      continue
    fi
    if [[ "$rel" == "$file_part" && "$named" == "$pat" && "$text" == *"$sub"* ]]; then
      return 0
    fi
  done
  return 1
}

scan_forbidden() {
  local file rel number text pat
  shopt -s nocasematch
  while IFS= read -r -d '' file; do
    rel="${file#./}"
    if [[ "$rel" == "$forbidden_file" || "$rel" == ".compliance/allowlist.txt" ]]; then
      continue
    fi
    case "$rel" in
      *.png | *.icns) continue ;;
    esac
    # Bash cannot hold a NUL, so an empty pattern would match every file.
    # grep -I reports no match for a binary file.
    if [[ -s "$file" ]] && ! LC_ALL=C grep -I -q . "$file"; then
      continue
    fi
    number=0
    while IFS= read -r text || [[ -n "$text" ]]; do
      number=$((number + 1))
      for pat in "${patterns[@]}"; do
        if [[ "$text" == *"$pat"* ]]; then
          if line_exempts "$rel" "$text" "$pat"; then
            continue
          fi
          echo "forbidden pattern in ${rel}:${number}"
          status=1
        fi
      done
      if [[ ${#extra_patterns[@]} -gt 0 ]]; then
        for pat in "${extra_patterns[@]}"; do
          if [[ "$text" == *"$pat"* ]]; then
            # Never consult the allowlist. File and line only.
            echo "${rel}:${number}"
            status=1
            break
          fi
        done
      fi
    done < "$file"
  done < <(find . -type f -not -path './.git/*' -not -path './.build/*' -not -path './build/*' -print0)
  shopt -u nocasematch
}

# 32-byte and 64-byte seeds, bounded so a longer token is not a hit.
# The pattern text is a character class, not a sample seed.
raw_key_line() {
  local text="$1"
  local seed32='(^|[^A-Za-z0-9+/])[A-Za-z0-9+/]{43}=([^A-Za-z0-9+/]|$)'
  local seed64='(^|[^A-Za-z0-9+/])[A-Za-z0-9+/]{86}==([^A-Za-z0-9+/]|$)'
  if [[ "$text" =~ $seed32 ]]; then
    return 0
  fi
  if [[ "$text" =~ $seed64 ]]; then
    return 0
  fi
  return 1
}

# Published minisign public keys live on these lines. They are 56 characters and
# do not match the seed lengths above. The exemption is only for those locations.
key_location_ok() {
  local rel="$1"
  local text="$2"
  local prev="$3"
  if [[ "$rel" == "config/product.env" && "$text" == *UPDATE_PUBLIC_KEY* ]]; then
    return 0
  fi
  case "$rel" in
    Resources/Info.plist | Resources/Info.plist.in)
      if [[ "$text" == *App1UpdatePublicKey* || "$prev" == *App1UpdatePublicKey* ]]; then
        return 0
      fi
      ;;
  esac
  return 1
}

scan_raw_keys() {
  local file rel number text prev
  while IFS= read -r -d '' file; do
    rel="${file#./}"
    case "$rel" in
      *.png | *.icns) continue ;;
    esac
    if [[ -s "$file" ]] && ! LC_ALL=C grep -I -q . "$file"; then
      continue
    fi
    number=0
    prev=""
    while IFS= read -r text || [[ -n "$text" ]]; do
      number=$((number + 1))
      if raw_key_line "$text"; then
        if ! key_location_ok "$rel" "$text" "$prev"; then
          echo "raw key material in ${rel}:${number}"
          status=1
        fi
      fi
      prev="$text"
    done < "$file"
  done < <(find . -type f -not -path './.git/*' -not -path './.build/*' -not -path './build/*' -print0)
}

# Temp tree: a forbidden pattern on an allowlisted line stays quiet, and a
# FORBIDDEN_EXTRA word on that same line still fails.
# Locals are visible to load_lists and scan_forbidden (bash dynamic scope) and
# do not change the caller's forbidden_file after the subshell returns.
self_test_scan() {
  local forbidden_file=".compliance/forbidden.txt"
  local allow_file=".compliance/allowlist.txt"
  local status=0
  FORBIDDEN_EXTRA=Zzmarker
  load_lists
  scan_forbidden
  printf 'STATUS=%s\n' "$status"
}

run_self_test() {
  local tmp out_file marker
  tmp="$(mktemp -d)"
  out_file="$(mktemp)"
  marker="$(printf '%s%s' 'ch' 'rome')"
  mkdir -p "${tmp}/.compliance"
  printf '%s\n' "$marker" > "${tmp}/.compliance/forbidden.txt"
  printf '%s\n' "note.txt:${marker}:mentions ${marker}" "note.txt:Zzmarker:Zzmarker" > "${tmp}/.compliance/allowlist.txt"
  printf '%s\n' "This line mentions ${marker} tooling and Zzmarker together." > "${tmp}/note.txt"
  (
    cd "$tmp"
    self_test_scan
  ) > "$out_file"
  if grep -q '^STATUS=0$' "$out_file"; then
    echo "self-test expected a failure" >&2
    rm -rf "$tmp" "$out_file"
    exit 1
  fi
  if grep -q 'forbidden pattern' "$out_file"; then
    echo "self-test exempted pattern was reported" >&2
    rm -rf "$tmp" "$out_file"
    exit 1
  fi
  if ! grep -q 'note.txt:1' "$out_file"; then
    echo "self-test did not report the extra pattern" >&2
    rm -rf "$tmp" "$out_file"
    exit 1
  fi
  rm -rf "$tmp" "$out_file"
  echo "compliance self-test passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit 0
fi

load_lists

check_spdx() {
  local file="$1"
  local first second third
  first="$(sed -n '1p' "$file")"
  second="$(sed -n '2p' "$file")"
  third="$(sed -n '3p' "$file")"
  if [[ "$first" == \#!* || "$first" == "// swift-tools-version:"* ]]; then
    first="$second"
    second="$third"
  fi
  local prefix="#"
  case "$file" in
    *.swift) prefix="//" ;;
  esac
  # Split the tag names so this check is not a second SPDX header.
  local copy_tag lic_tag
  copy_tag="SPDX-FileCopyright""Text: 2026 Wyvern Contributors"
  lic_tag="SPDX-License-""Identifier: MIT"
  if [[ "$first" != "$prefix $copy_tag" ]]; then
    echo "missing copyright header: ${file#./}"
    status=1
  fi
  if [[ "$second" != "$prefix $lic_tag" ]]; then
    echo "missing license header: ${file#./}"
    status=1
  fi
}

while IFS= read -r -d '' file; do
  check_spdx "$file"
done < <(find . -type f \( -name '*.swift' -o -name '*.sh' -o -name '*.py' -o -name '*.yml' \) \
  -not -path './.git/*' -not -path './.build/*' -not -path './build/*' -print0)

scan_forbidden
scan_raw_keys

secret_marker="untrusted comment: minisign secret ""key"
if LC_ALL=C grep -R -n -F "$secret_marker" \
    --exclude-dir=.git --exclude-dir=.build --exclude-dir=build . >/dev/null 2>&1; then
  echo "signing-key material must not be in the tree"
  status=1
fi

# Mandatory license gate. Phrases are assembled so this file does not contain them.
# LICENSES/ and the .compliance list files are the only exclusions.
check_license_phrases() {
  local gnu="GNU"
  local phrases=()
  local rel phrase hits hit line_no
  phrases+=("${gnu} General Public License")
  phrases+=("${gnu} Lesser General Public")
  phrases+=("${gnu} Affero")
  phrases+=("SPDX-License-""Identifier: GPL")
  phrases+=("L""GPL-")
  phrases+=("A""GPL-")
  while IFS= read -r -d '' rel; do
    case "$rel" in
      LICENSES/* | .compliance/forbidden.txt | .compliance/allowlist.txt)
        continue
        ;;
    esac
    [[ -f "$rel" ]] || continue
    if [[ -s "$rel" ]] && ! LC_ALL=C grep -I -q . "$rel"; then
      continue
    fi
    for phrase in "${phrases[@]}"; do
      hits="$(grep -n -F -i -I -e "$phrase" -- "$rel" || true)"
      [[ -z "$hits" ]] && continue
      while IFS= read -r hit || [[ -n "$hit" ]]; do
        [[ -z "$hit" ]] && continue
        line_no="${hit%%:*}"
        echo "disallowed license phrase in ${rel}:${line_no}"
        status=1
      done <<< "$hits"
    done
  done < <(git ls-files -z)
}
check_license_phrases

while IFS= read -r pat || [[ -n "$pat" ]]; do
  pat="${pat#"${pat%%[![:space:]]*}"}"
  pat="${pat%"${pat##*[![:space:]]}"}"
  [[ -z "$pat" ]] && continue
  [[ "$pat" == \#* ]] && continue
  if [[ "$pat" == .* && "$pat" != */* && ${#pat} -le 5 ]]; then
    while IFS= read -r -d '' found; do
      echo "font file: ${found#./}"
      status=1
    done < <(find . -type f -name "*${pat}" -not -path './.git/*' -not -path './.build/*' -not -path './build/*' -print0)
  fi
done < "$forbidden_file"

# Product identity: scripts, Info.plist, project.yml, and AppInfo must match config/product.env.
# shellcheck disable=SC1091
. "$ROOT/scripts/load-product-env.sh"
if [[ "$BUNDLE_NAME" != "$DISPLAY_NAME" ]]; then
  echo "BUNDLE_NAME does not match DISPLAY_NAME"
  status=1
fi
if ! grep -Fq "displayName = \"${DISPLAY_NAME}\"" Sources/App1Core/AppInfo.swift; then
  echo "AppInfo.displayName does not match DISPLAY_NAME"
  status=1
fi
if ! grep -Fq "shortName = \"${DISPLAY_NAME}\"" Sources/App1Core/AppInfo.swift; then
  echo "AppInfo.shortName does not match DISPLAY_NAME"
  status=1
fi
if ! grep -Fq "productName = \"${PRODUCT_NAME}\"" Sources/App1Core/AppInfo.swift; then
  echo "AppInfo.productName does not match PRODUCT_NAME"
  status=1
fi
if ! grep -Fq "fallbackBundleIdentifier = \"${BUNDLE_ID}\"" Sources/App1Core/AppInfo.swift; then
  echo "AppInfo.fallbackBundleIdentifier does not match BUNDLE_ID"
  status=1
fi
if ! grep -Fq "marketingVersion = \"${VERSION}\"" Sources/App1Core/AppInfo.swift; then
  echo "AppInfo.marketingVersion does not match VERSION"
  status=1
fi
if ! grep -Fq "<string>${BUNDLE_ID}</string>" Resources/Info.plist; then
  echo "Resources/Info.plist bundle id does not match BUNDLE_ID"
  status=1
fi
if ! python3 - "$DISPLAY_NAME" "$EXECUTABLE_NAME" "$BUNDLE_ID" Resources/Info.plist <<'PY'
import plistlib
import sys

display, executable, bundle_id, path = sys.argv[1:]
with open(path, "rb") as handle:
    info = plistlib.load(handle)
ok = True
if info.get("CFBundleDisplayName") != display:
    print("CFBundleDisplayName does not match DISPLAY_NAME")
    ok = False
if info.get("CFBundleName") != display:
    print("CFBundleName does not match DISPLAY_NAME")
    ok = False
if info.get("CFBundleExecutable") != executable:
    print("CFBundleExecutable does not match EXECUTABLE_NAME")
    ok = False
if info.get("CFBundleIdentifier") != bundle_id:
    print("CFBundleIdentifier does not match BUNDLE_ID")
    ok = False
sys.exit(0 if ok else 1)
PY
then
  status=1
fi
if ! grep -Fq "<string>${VERSION}</string>" Resources/Info.plist; then
  echo "Resources/Info.plist version does not match VERSION"
  status=1
fi
if ! grep -Fq "PRODUCT_NAME: ${PRODUCT_NAME}" project.yml; then
  echo "project.yml PRODUCT_NAME does not match PRODUCT_NAME"
  status=1
fi
if ! grep -Fq "PRODUCT_BUNDLE_IDENTIFIER: ${BUNDLE_ID}" project.yml; then
  echo "project.yml PRODUCT_BUNDLE_IDENTIFIER does not match BUNDLE_ID"
  status=1
fi
generated="$(mktemp)"
generate_info_plist "$generated"
if ! cmp -s "$generated" Resources/Info.plist; then
  echo "Resources/Info.plist is out of date; regenerate from Resources/Info.plist.in"
  status=1
fi
rm -f "$generated"

if [[ "$status" -ne 0 ]]; then
  exit 1
fi
echo "compliance check passed"
