#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

"""Write synthetic bookmark import fixtures under Tests/App1CoreTests/Fixtures."""

import sqlite3
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests" / "App1CoreTests" / "Fixtures"


def write_places(path: Path) -> None:
    if path.exists():
        path.unlink()
    conn = sqlite3.connect(str(path))
    cur = conn.cursor()
    cur.execute(
        "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT)"
    )
    cur.execute(
        "CREATE TABLE moz_bookmarks ("
        "id INTEGER PRIMARY KEY, type INTEGER, parent INTEGER, position INTEGER, "
        "title TEXT, fk INTEGER)"
    )
    cur.execute(
        "CREATE TABLE moz_historyvisits ("
        "id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER)"
    )
    # type 1 bookmark, 2 folder, 3 separator
    rows = [
        (1, 2, 0, 0, "", None),
        (2, 2, 1, 0, "menu", None),
        (3, 2, 1, 1, "toolbar", None),
        (4, 2, 1, 2, "unfiled", None),
        (5, 2, 1, 3, "mobile", None),
        (6, 2, 1, 4, "tags", None),
        (7, 2, 3, 0, "Dev", None),
    ]
    cur.executemany(
        "INSERT INTO moz_bookmarks (id, type, parent, position, title, fk) VALUES (?,?,?,?,?,?)",
        rows,
    )
    places = [
        (1, "https://example.com/dev", "Dev Site"),
        (2, "https://example.org/menu", "Menu Site"),
        (3, "place:type=6&sort=2", "Most Visited"),
        (4, "javascript:alert(1)", "Scripted"),
        (5, "https://dupe.example/", "Dupe A"),
        (6, "https://dupe.example", "Dupe B"),
        (7, "https://secret-history.example/visited", "Should not import"),
        (8, "https://mobile.example/", "Mobile Site"),
        (9, "data:text/html,hi", "Data link"),
    ]
    cur.executemany("INSERT INTO moz_places (id, url, title) VALUES (?,?,?)", places)
    bookmarks = [
        (8, 1, 7, 0, "Dev Site", 1),
        (9, 1, 2, 0, "Menu Site", 2),
        (10, 3, 3, 1, "", None),
        (11, 1, 3, 2, "Most Visited", 3),
        (12, 1, 4, 0, "Scripted", 4),
        (13, 1, 4, 1, "Dupe A", 5),
        (14, 1, 4, 2, "Dupe B", 6),
        (15, 1, 5, 0, "Mobile Site", 8),
        (16, 1, 4, 3, "Data link", 9),
    ]
    cur.executemany(
        "INSERT INTO moz_bookmarks (id, type, parent, position, title, fk) VALUES (?,?,?,?,?,?)",
        bookmarks,
    )
    cur.execute(
        "INSERT INTO moz_historyvisits (id, place_id, visit_date) VALUES (1, 7, 12345)"
    )
    conn.commit()
    conn.close()


def write_places_wal(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    sqlite = directory / "places.sqlite"
    write_places(sqlite)
    conn = sqlite3.connect(str(sqlite))
    conn.execute("PRAGMA wal_autocheckpoint=0")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute(
        "INSERT INTO moz_places (id, url, title) VALUES (20, 'https://wal.example/extra', 'WAL Extra')"
    )
    conn.execute(
        "INSERT INTO moz_bookmarks (id, type, parent, position, title, fk) "
        "VALUES (20, 1, 2, 1, 'WAL Extra', 20)"
    )
    conn.commit()
    conn.close()
    for suffix in ("-wal", "-shm"):
        sidecar = Path(str(sqlite) + suffix)
        if not sidecar.exists():
            sidecar.write_bytes(b"")


def write_html(path: Path) -> None:
    deep_open = []
    deep_close = []
    for index in range(1, 41):
        deep_open.append(f"<DT><H3>L{index}</H3>\n<DL><p>\n")
        deep_close.append("</DL><p>\n")
    deep = "".join(deep_open) + '<DT><A HREF="https://deep.example/leaf">Deep leaf</A>\n' + "".join(
        reversed(deep_close)
    )
    body = f"""<!DOCTYPE NETSCAPE-Bookmark-file-1>
<!-- This is an untrusted synthetic fixture. -->
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3>Reading</H3>
    <DL><p>
        <DT><A HREF="https://example.com/a" ADD_DATE="1700000000" ICON="data:image/png;base64,AAAA">Tom &amp; Jerry</A>
        <DT><A HREF="javascript:alert(1)">JS link</A>
        <DT><A HREF="data:text/html,hi" ICON_URI="https://example.com/icon.png">Data link</A>
        <DT><A HREF="https://example.com/script">Hello <script>alert(1)</script> world</A>
        <DT><A HREF="https://example.com/a">Duplicate</A>
        <DT><A HREF="vbscript:msg">VB</A>
        <DT><A HREF="file:///tmp/x">File</A>
        <DT><A HREF="place:foo=1">Place</A>
    </DL><p>
{deep}
</DL><p>
"""
    path.write_text(body, encoding="utf-8")


def write_family_json(path: Path) -> None:
    body = """{
  "roots": {
    "bookmark_bar": {
      "children": [
        {
          "children": [
            {"name": "Dev docs", "type": "url", "url": "https://docs.example.org/"},
            {"name": "Bad", "type": "url", "url": "javascript:alert(1)"}
          ],
          "name": "Dev",
          "type": "folder"
        },
        {"name": "Home", "type": "url", "url": "https://example.com/"}
      ],
      "name": "Bookmarks Bar",
      "type": "folder"
    },
    "other": {
      "children": [
        {"name": "Dup", "type": "url", "url": "https://example.com"},
        {"name": "Other site", "type": "url", "url": "http://localhost/other"}
      ],
      "name": "Other Bookmarks",
      "type": "folder"
    },
    "synced": {
      "children": [
        {"name": "Phone", "type": "url", "url": "https://mobile.example/app"}
      ],
      "name": "Mobile Bookmarks",
      "type": "folder"
    }
  }
}
"""
    path.write_text(body, encoding="utf-8")


def main() -> int:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    write_places(FIXTURES / "places.sqlite")
    wal_dir = FIXTURES / "places-wal"
    if wal_dir.exists():
        shutil.rmtree(wal_dir)
    write_places_wal(wal_dir)
    write_html(FIXTURES / "bookmarks.html")
    write_family_json(FIXTURES / "browser-family.json")
    print(f"wrote fixtures in {FIXTURES}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
