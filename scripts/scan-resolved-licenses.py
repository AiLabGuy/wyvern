#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

"""Check Package.resolved, checkout licenses, and THIRD_PARTY_LICENSES.md.

Run this after `swift build`, when the resolver has written Package.resolved and
cloned checkouts. SwiftTerm 1.11.2 does not pull swift-png and has no Metal
shaders. A later pin that adds a checkout NOTICE must copy that NOTICE into
THIRD_PARTY_LICENSES.md; this script fails if any checkout NOTICE is missing.
"""

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent

COPYRIGHT_LINES = (
    "Miguel de Icaza",
    "The xterm.js authors",
    "SourceLair Private Company",
    "Christopher Jeffrey",
)
ARCHIVE_SHA256 = "dd4bd355903a900c0af66095c6c8d3cb5ec94cc4e6358af6e4aac033fce351b7"
COMMIT = "b1262db5b6bea699a8260a8c66999436c508ca56"
VERSION = "1.11.2"
REJECTED = ("1.19.0", "2019-2026", "464df520", "09680d05")


def resolved_path():
    candidates = [
        ROOT / "Package.resolved",
        ROOT / ".swiftpm" / "Package.resolved",
    ]
    for path in candidates:
        if path.is_file():
            return path
    return None


def pins_from(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    raw = data.get("pins")
    if raw is None and isinstance(data.get("object"), dict):
        raw = data["object"].get("pins")
    if not isinstance(raw, list):
        return []
    return [pin for pin in raw if isinstance(pin, dict)]


def pin_state(pin):
    state = pin.get("state") if isinstance(pin.get("state"), dict) else {}
    identity = str(pin.get("identity") or pin.get("package") or "")
    version = str(state.get("version") or "") if isinstance(state, dict) else ""
    revision = str(state.get("revision") or "") if isinstance(state, dict) else ""
    return identity, version, revision


def license_texts(checkout):
    names = {"LICENSE", "LICENSE.TXT", "LICENSE.MD", "COPYING", "NOTICE", "NOTICE.TXT", "NOTICE.MD"}
    texts = []
    for path in checkout.iterdir():
        if not path.is_file() or path.name.upper() not in names:
            continue
        try:
            texts.append(path.read_text(encoding="utf-8", errors="replace"))
        except OSError as error:
            print(f"could not read {path}: {error}", file=sys.stderr)
            return None
    return texts


def copyleft(text):
    # Tokens are assembled so this source file does not contain those spellings.
    family = ("ag" + "pl", "lg" + "pl", "g" + "pl")
    token = re.compile(r"(?i)(?<![A-Za-z0-9])(?:" + "|".join(family) + r")(?![A-Za-z0-9])")
    phrase = " ".join(["gnu", "general", "public", "license"])
    lowered = text.lower()
    return token.search(text) is not None or phrase in lowered


def rejected(text, label):
    for token in REJECTED:
        if token in text:
            print(f"{label} still describes the rejected SwiftTerm pin ({token})", file=sys.stderr)
            return True
    return False


def main() -> int:
    path = resolved_path()
    if path is None:
        print("Package.resolved is missing. Run swift build before this scan.", file=sys.stderr)
        return 1
    pins = pins_from(path)
    if not pins:
        print(f"{path} has no pins", file=sys.stderr)
        return 1

    swiftterm = None
    for pin in pins:
        identity, version, revision = pin_state(pin)
        if identity.lower() == "swiftterm":
            swiftterm = (version, revision)
            break
    if swiftterm is None:
        print("Package.resolved does not pin SwiftTerm", file=sys.stderr)
        return 1
    version, revision = swiftterm
    if version != VERSION or not revision.startswith(COMMIT):
        print(f"SwiftTerm pin is {version} {revision}, expected {VERSION} {COMMIT}", file=sys.stderr)
        return 1

    third = ROOT / "THIRD_PARTY_LICENSES.md"
    if not third.is_file():
        print("THIRD_PARTY_LICENSES.md is missing", file=sys.stderr)
        return 1
    body = third.read_text(encoding="utf-8")
    for line in COPYRIGHT_LINES:
        if line not in body:
            print(f"THIRD_PARTY_LICENSES.md is missing copyright line: {line}", file=sys.stderr)
            return 1
    if "Permission is hereby granted" not in body:
        print("THIRD_PARTY_LICENSES.md is missing the MIT grant paragraph", file=sys.stderr)
        return 1
    if "2019-2022" not in body:
        print("THIRD_PARTY_LICENSES.md is missing the SwiftTerm copyright years 2019-2022", file=sys.stderr)
        return 1
    if ARCHIVE_SHA256 not in body or COMMIT not in body or VERSION not in body:
        print("THIRD_PARTY_LICENSES.md is missing the SwiftTerm version, commit, or archive sha256", file=sys.stderr)
        return 1
    if rejected(body, "THIRD_PARTY_LICENSES.md"):
        return 1

    acknowledgements = ROOT / "Sources" / "Wyvern" / "Acknowledgements.swift"
    if acknowledgements.is_file():
        notice = acknowledgements.read_text(encoding="utf-8")
        if COMMIT not in notice or VERSION not in notice or "2019-2022" not in notice:
            print("Acknowledgements.swift does not match SwiftTerm 1.11.2", file=sys.stderr)
            return 1
        if rejected(notice, "Acknowledgements.swift"):
            return 1

    checkouts = ROOT / ".build" / "checkouts"
    if not checkouts.is_dir():
        print(".build/checkouts is missing. Run swift build before this scan.", file=sys.stderr)
        return 1

    failures = []
    notice_count = 0
    for child in sorted(checkouts.iterdir()):
        if not child.is_dir():
            continue
        texts = license_texts(child)
        if texts is None:
            return 1
        for text in texts:
            if copyleft(text):
                failures.append(child.name)
                break
        if child.name.lower() == "swiftterm":
            metal = [item.name for item in child.rglob("*.metal")]
            if metal:
                print(f"SwiftTerm checkout contains Metal shaders: {', '.join(metal)}", file=sys.stderr)
                return 1
        notice = None
        for name in ("NOTICE", "NOTICE.txt", "NOTICE.md"):
            candidate = child / name
            if candidate.is_file():
                notice = candidate.read_text(encoding="utf-8", errors="replace").strip()
                break
        if notice:
            notice_count += 1
            if notice not in body:
                print(f"NOTICE from {child.name} is not copied into THIRD_PARTY_LICENSES.md", file=sys.stderr)
                return 1

    if failures:
        print("copyleft license family detected in checkouts:")
        for item in failures:
            print(item)
        return 1

    print(f"resolved licenses ok: SwiftTerm {version} {revision[:12]} notices={notice_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
