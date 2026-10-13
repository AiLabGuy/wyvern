# Contributing

## Developer Certificate of Origin

This project uses the [Developer Certificate of Origin](https://developercertificate.org/).

There is no CLA. A contributor license agreement is not required.

Every commit must include a `Signed-off-by` trailer. `git commit -s` adds that trailer for the author identity configured in git. By adding the trailer you certify the Developer Certificate of Origin.

## What to change

Keep the application on Apple system frameworks. Do not add a third-party runtime dependency.

The App1Core library must stay free of AppKit so `swift test` can build it without the application target. Put address parsing, bookmarks, settings, media permission rules, bookmark import, update policy, and similar rules there, and add XCTest coverage. System SQLite and CryptoKit are allowed.

UI code belongs in `Sources/App1` and stays on the main actor.

## Checks before you send a change

```bash
bash scripts/compliance-check.sh
python3 -m py_compile scripts/check-licenses.py scripts/ui-test-server.py scripts/make-import-fixtures.py
python3 scripts/ui-test-server.py --self-test
bash -n scripts/build-app.sh scripts/make-dmg.sh scripts/make-icns.sh scripts/gen-third-party.sh scripts/compliance-check.sh scripts/load-product-env.sh
```

On macOS, also run `swift test` and `bash scripts/build-app.sh`.

CI builds the disk image, then runs the real GUI tests on the macOS build job. Those tests need an Aqua session and Accessibility permission for the process that launches the job. A missing permission fails the job. Screenshots run after the GUI tests and do not fail the job. A non-gating Benchmark step runs after screenshots against the already-built release app (`App1Bench`); a locked session prints `BENCH_BLOCKED_SCREEN_LOCKED` and does not fail the job. See [docs/PERFORMANCE.md](docs/PERFORMANCE.md). A non-gating Zen diagnostic (`App1Diag --zen-diagnose`) runs after the app build. An extra `swift test -Xswiftc -DWYVERN_DEV_UPDATER` covers the debug-only HTTP update path and is gating.

Do not commit generated `*.xcodeproj` directories, `.env` files, or secrets.
