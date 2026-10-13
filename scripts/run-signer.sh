#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

# Runs WyvernUpdateSigner (or any command) under a 60 second alarm. macOS has no timeout(1);
# perl's alarm survives exec, so SIGALRM ends the signer itself. A keychain dialog or any
# other prompt that would block CI becomes a loud SIGNING_TIMEOUT failure, never a hang.

set -uo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: scripts/run-signer.sh SIGNER [ARGS...]" >&2
  exit 2
fi

perl -e 'alarm 60; exec @ARGV or die "exec failed: $!\n"' "$@"
code=$?
# 142 is 128 + SIGALRM (14).
if [[ "$code" -eq 142 ]]; then
  echo "error: SIGNING_TIMEOUT: $(basename "$1") did not finish within 60 s (likely an interactive keychain prompt); see SECURITY.md" >&2
  exit 1
fi
exit "$code"
