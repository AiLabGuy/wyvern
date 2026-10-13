#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

"""Serve the GUI-test fixtures on 127.0.0.1 and write the chosen port to a file."""

import argparse
import math
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import URLError
from urllib.parse import unquote, urlparse
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests-ui" / "fixtures"

HTML = {
    "plain.html",
    "enter.html",
    "media.html",
    "frame.html",
    "media-capture.html",
    "bench.html",
}
BINS = {
    "blob.bin",
    "data.bin",
}
IMAGES = {
    "bench.png",
}


def wav_bytes():
    rate = 8000
    count = int(rate * 0.2)
    frames = bytearray()
    for index in range(count):
        sample = int(3000 * math.sin(2 * math.pi * 440 * index / rate))
        frames += struct.pack("<h", sample)
    data_size = len(frames)
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + data_size,
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        rate,
        rate * 2,
        2,
        16,
        b"data",
        data_size,
    )
    return header + bytes(frames)


TONE = wav_bytes()


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        name = unquote(urlparse(self.path).path.lstrip("/"))
        if name == "tone.wav":
            self._send(200, TONE, {"Content-Type": "audio/wav"})
            return
        if name in HTML or name in BINS or name in IMAGES or name == "attach.bin":
            path = FIXTURES / name
            if not path.is_file():
                self.send_error(404)
                return
            body = path.read_bytes()
            headers = {}
            if name in HTML:
                headers["Content-Type"] = "text/html; charset=utf-8"
            elif name in IMAGES:
                headers["Content-Type"] = "image/png"
            else:
                headers["Content-Type"] = "application/octet-stream"
            if name == "attach.bin":
                headers["Content-Disposition"] = 'attachment; filename="attach.bin"'
            self._send(200, body, headers)
            return
        self.send_error(404)

    def _send(self, status, body, headers):
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


def make_server():
    return ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)


def header_value(headers, name):
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return ""


def disposition_token(value):
    return value.split(";", 1)[0].strip().lower()


def check_fixture(base, name, expect):
    url = base + "/" + name
    try:
        with urlopen(url, timeout=5) as response:
            status = response.status
            headers = dict(response.headers.items())
            body = response.read()
    except URLError as error:
        return f"{name} request failed: {error}"
    if status != 200:
        return f"{name} status {status}"
    content_type = header_value(headers, "Content-Type")
    if expect["type"] not in content_type:
        return f"{name} content-type {content_type}"
    disposition = header_value(headers, "Content-Disposition")
    token = disposition_token(disposition)
    if expect.get("attachment"):
        if token != "attachment":
            return f"{name} disposition {disposition}"
    elif token == "attachment":
        return f"{name} unexpected attachment"
    marker = expect.get("body")
    if marker is not None and marker not in body:
        return f"{name} body missing marker"
    prefix = expect.get("prefix")
    if prefix is not None and not body.startswith(prefix):
        return f"{name} bad prefix"
    return ""


def self_test():
    server = make_server()
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{port}"
    expectations = [
        ("plain.html", {"type": "text/html", "body": b"Plain test page"}),
        ("enter.html", {"type": "text/html", "body": b"Entered test page"}),
        ("media.html", {"type": "text/html", "body": b"Media test page"}),
        ("frame.html", {"type": "text/html", "body": b"Frame"}),
        ("media-capture.html", {"type": "text/html", "body": b"Media capture test"}),
        ("bench.html", {"type": "text/html", "body": b"Bench page"}),
        ("bench.png", {"type": "image/png", "prefix": b"\x89PNG"}),
        ("attach.bin", {"type": "application/octet-stream", "attachment": True}),
        ("blob.bin", {"type": "application/octet-stream"}),
        ("data.bin", {"type": "application/octet-stream"}),
        ("tone.wav", {"type": "audio/wav", "prefix": b"RIFF"}),
    ]
    failures = []
    try:
        for name, expect in expectations:
            reason = check_fixture(base, name, expect)
            if reason:
                failures.append(reason)
                print(f"SELF_TEST {name} FAIL {reason}")
            else:
                print(f"SELF_TEST {name} PASS")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
    if failures:
        print(f"SELF_TEST failed {len(failures)}")
        return 1
    print("SELF_TEST ok")
    return 0


def serve(port_file):
    server = make_server()
    port = server.server_address[1]
    path = Path(port_file)
    path.write_text(f"{port}\n", encoding="utf-8")
    try:
        server.serve_forever()
    finally:
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description="Serve Wyvern Browser GUI test fixtures.")
    parser.add_argument("--port-file", default="", help="File that receives the bound port.")
    parser.add_argument("--self-test", action="store_true", help="Start, fetch each fixture, stop.")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.port_file:
        print("ui-test-server: --port-file is required", file=sys.stderr)
        return 2
    serve(args.port_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
