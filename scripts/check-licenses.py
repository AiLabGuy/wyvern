#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

"""Fail when a scancode JSON report contains a copyleft family this repo rejects."""

import json
import re
import sys
from pathlib import Path


def values_from(node, found):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in {
                "spdx_license_key",
                "key",
                "detected_license_expression",
                "detected_license_expression_spdx",
                "license_expression",
                "license_expression_spdx",
                "name",
            }:
                if isinstance(value, str):
                    found.append(value)
            else:
                values_from(value, found)
    elif isinstance(node, list):
        for item in node:
            values_from(item, found)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-licenses.py SCANCODE_JSON", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    data = json.loads(path.read_text(encoding="utf-8"))
    files = data.get("files", [])
    if not isinstance(files, list):
        print("scancode JSON has no files list", file=sys.stderr)
        return 2

    # Tokens are assembled so this source file does not contain those spellings.
    family = ("ag" + "pl", "lg" + "pl", "g" + "pl")
    token = re.compile(r"(?i)(?<![A-Za-z0-9])(?:" + "|".join(family) + r")(?![A-Za-z0-9])")
    phrase = " ".join(["general", "public", "license"])
    failures = []
    for entry in files:
        if not isinstance(entry, dict):
            continue
        texts = []
        for field in (
            "licenses",
            "license_detections",
            "detected_license_expression",
            "detected_license_expression_spdx",
        ):
            if field in entry:
                values_from(entry[field], texts)
        blob = "\n".join(texts)
        lowered = blob.lower()
        if token.search(blob) or phrase in lowered:
            failures.append(str(entry.get("path", "<unknown>")))

    if failures:
        print("copyleft license family detected:")
        for item in failures:
            print(item)
        return 1
    print("no rejected license family in scan")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
