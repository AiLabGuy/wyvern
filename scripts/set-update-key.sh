#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

# Replaces the pinned minisign public key in product.env, Info.plist, the signer,
# and every test or doc that embeds the current key line. Does not sign or build.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  echo "usage: scripts/set-update-key.sh PUBKEY" >&2
  exit 2
}

if [[ $# -ne 1 ]]; then
  usage
fi

NEW_KEY="$1"
PINNED_KEY="RELEASE_PUBLIC_KEY_PLACEHOLDER"

python3 - "$NEW_KEY" "$PINNED_KEY" "$ROOT" <<'PY'
import base64
import pathlib
import sys

new_key = sys.argv[1].strip()
pinned = sys.argv[2]
root = pathlib.Path(sys.argv[3])


def decode_key(text: str) -> bytes:
    if not text.startswith("RW"):
        raise SystemExit("error: public key must start with RW")
    try:
        raw = base64.b64decode(text)
    except Exception:
        raise SystemExit("error: public key is not valid base64")
    if len(raw) != 42:
        raise SystemExit("error: public key must decode to 42 bytes")
    if raw[:2] != b"Ed":
        raise SystemExit("error: public key must be a legacy Ed (minisign) key")
    if base64.b64encode(raw).decode("ascii") != text:
        raise SystemExit("error: public key is not canonical base64")
    return raw


def fingerprint(raw: bytes) -> str:
    key_id = raw[2:10]
    return "".join("%02X" % b for b in key_id[::-1])


new_raw = decode_key(new_key)
new_fp = fingerprint(new_raw)

env_path = root / "config" / "product.env"
old_key = pinned
if env_path.is_file():
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("UPDATE_PUBLIC_KEY="):
            value = line.split("=", 1)[1].strip()
            if value:
                old_key = value
            break

if old_key == new_key:
    print("UPDATE_PUBLIC_KEY is already %s" % new_key)
    sys.exit(0)

try:
    old_fp = fingerprint(decode_key(old_key))
except SystemExit:
    old_fp = ""

skip_dirs = {".git", ".build", "build"}
changed = 0
for path in root.rglob("*"):
    if not path.is_file():
        continue
    if any(part in skip_dirs for part in path.parts):
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    updated = text.replace(old_key, new_key)
    if old_fp and old_fp != new_fp:
        updated = updated.replace(old_fp, new_fp)
    if updated != text:
        path.write_text(updated, encoding="utf-8")
        rel = path.relative_to(root).as_posix()
        print("updated %s" % rel)
        changed += 1

if changed == 0:
    raise SystemExit("error: did not find the current public key in the tree")
print("UPDATE_PUBLIC_KEY=%s" % new_key)
print("key id %s" % new_fp)
PY
