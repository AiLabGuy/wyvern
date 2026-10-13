#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

# Generates a fresh minisign key pair for signing public releases, OUTSIDE the repository,
# then pins its public key with scripts/set-update-key.sh.
#
#   bash scripts/new-release-key.sh [KEY_DIR]      # default KEY_DIR: ~/.minisign
#
# The secret key stays in KEY_DIR (never commit it; *.key is gitignored). minisign asks for a
# password; for CI, store the secret key file's contents as the repo secret MINISIGN_SECRET_KEY and
# the password as MINISIGN_PASSWORD (see .github/workflows/release.yml).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_DIR="${1:-$HOME/.minisign}"

if ! command -v minisign >/dev/null 2>&1; then
  echo "minisign is required (macOS: brew install minisign)" >&2
  exit 1
fi
case "$(cd "$(dirname "$KEY_DIR")" 2>/dev/null && pwd)/$(basename "$KEY_DIR")/" in
  "$ROOT"/*)
    echo "refusing to write the secret key inside the repository: $KEY_DIR" >&2
    exit 1
    ;;
esac

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
secret="$KEY_DIR/wyvern-release.key"
public="$KEY_DIR/wyvern-release.pub"
if [[ -e "$secret" ]]; then
  echo "$secret already exists; refusing to overwrite it" >&2
  exit 1
fi
minisign -G -p "$public" -s "$secret"
chmod 600 "$secret"
pubkey="$(sed -n '2p' "$public")"
echo "secret key: $secret (keep it private and backed up)"
echo "public key: $public"
bash "$ROOT/scripts/set-update-key.sh" "$pubkey"
