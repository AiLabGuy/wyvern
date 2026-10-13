#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])

def product_name():
    env = root / "config" / "product.env"
    for line in env.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("PRODUCT_NAME="):
            return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("PRODUCT_NAME missing from config/product.env")

SWIFT_TERM_MIT = """Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
"""

def load_pins():
    candidates = [
        root / "Package.resolved",
        root / ".swiftpm" / "Package.resolved",
    ]
    for path in candidates:
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        raw = data.get("pins")
        if raw is None and isinstance(data.get("object"), dict):
            raw = data["object"].get("pins")
        if isinstance(raw, list):
            return raw, path
    return [], None

def pin_fields(pin):
    name = str(pin.get("identity") or pin.get("package") or "unknown")
    location = str(pin.get("location") or pin.get("repositoryURL") or "")
    state = pin.get("state") if isinstance(pin.get("state"), dict) else {}
    version = ""
    revision = ""
    if isinstance(state, dict):
        version = str(state.get("version") or "")
        revision = str(state.get("revision") or "")
    return name, version, revision, location

def notice_files():
    found = []
    checkouts = root / ".build" / "checkouts"
    if not checkouts.is_dir():
        return found
    for child in sorted(checkouts.iterdir()):
        if not child.is_dir():
            continue
        for name in ("NOTICE", "NOTICE.txt", "NOTICE.md"):
            path = child / name
            if path.is_file():
                text = path.read_text(encoding="utf-8", errors="replace").strip()
                if text:
                    found.append((child.name, text))
                break
    return found

pins, pin_path = load_pins()
name = product_name()
lines = ["# Third-party licenses", ""]
lines.append(
    "The app icon (assets/icon: wyvern-icon.svg, wyvern-icon-small.svg and their PNG renders, bundled as AppIcon.icns) is licensed CC-BY-4.0 by Wyvern Browser contributors; no trademark rights are granted. Created with Grok. Provenance is in ASSETS.md and the full license text is in LICENSES/CC-BY-4.0.txt. See TRADEMARKS.md."
)
lines.append("")
lines.append("## SwiftTerm")
lines.append("")
lines.append("SwiftTerm 1.11.2")
lines.append("https://github.com/migueldeicaza/SwiftTerm")
lines.append("commit b1262db5b6bea699a8260a8c66999436c508ca56")
lines.append("GitHub tag archive sha256 dd4bd355903a900c0af66095c6c8d3cb5ec94cc4e6358af6e4aac033fce351b7")
lines.append("https://github.com/migueldeicaza/SwiftTerm/archive/refs/tags/v1.11.2.tar.gz")
lines.append("")
lines.append("The SwiftTerm library is MIT, which is compatible with this project's MIT license. The full license text follows.")
lines.append("")
lines.append(SWIFT_TERM_MIT.rstrip())
lines.append("")
lines.append(
    "SwiftTerm 1.11.2 does not depend on swift-png. That package is Apache-2.0 and is used by unreleased development versions for non-Apple builds only. If a later pin adds swift-png and the checkout ships a NOTICE file, copy that NOTICE into this file."
)
lines.append(
    "swift-argument-parser is Apache-2.0. SwiftTerm uses it only in a command-line target, so a build that links the SwiftTerm library does not link it."
)
lines.append("swift-docc-plugin is a build-time plugin.")
lines.append(
    "package-benchmark is Apache-2.0 and is not linked. It is used only by the SwiftTerm benchmark target."
)
lines.append(
    "SwiftTerm 1.11.2 contains no Metal shader files. The library product is linked. The command-line targets, the benchmark target, and the docc plugin are not."
)
lines.append(
    "SwiftTerm bundles no font. " + name + " uses the system monospace font and does not bundle a font."
)
lines.append("")
if not pins:
    lines.append("No resolved third-party pins were found. Package.swift declares SwiftTerm exactly 1.11.2.")
    lines.append("")
else:
    where = pin_path.relative_to(root).as_posix() if pin_path is not None else "Package.resolved"
    lines.append("Resolved pins from " + where + ":")
    lines.append("")
    for pin in pins:
        if not isinstance(pin, dict):
            continue
        identity, version, revision, location = pin_fields(pin)
        shown = version or revision
        lines.append(("- " + identity + " " + shown + " " + location).rstrip())
        if revision and version:
            lines.append("  revision " + revision)
    lines.append("")

notices = notice_files()
if notices:
    lines.append("## Checkout notices")
    lines.append("")
    for checkout, text in notices:
        lines.append("### " + checkout)
        lines.append("")
        lines.append(text)
        lines.append("")

(root / "THIRD_PARTY_LICENSES.md").write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
