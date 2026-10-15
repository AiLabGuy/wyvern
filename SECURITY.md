# Security

## Reporting a vulnerability

Please report a vulnerability **privately** through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** (GitHub private vulnerability reporting). Do not open a public issue or pull request for an undisclosed vulnerability.

Include the version you ran (Wyvern Browser > About), your macOS version, and steps to reproduce. This is a small volunteer project: expect an acknowledgement within about a week, and a fix prepared before public discussion where one is possible. There is no bug bounty.

What was reviewed before v0.1.0, how, and what is still known to be weak is in [docs/SECURITY-REPORT.md](docs/SECURITY-REPORT.md).

## Supported versions

| Version | Supported |
| --- | --- |
| 0.1.x | yes (latest release only) |
| older | no |

Wyvern Browser runs on macOS 13 and later.

## Site reputation

Wyvern Browser does not include a Safe Browsing or site-reputation service. It does not send the addresses you visit to a reputation vendor, and it does not block sites using a vendor list. You decide which addresses to open.

## Updates and crash reports

Wyvern Browser does not upload crash reports. Updates never run on their own. Check for Updates… (in the app menu or in Settings > Updates) shows the available version and commit. Nothing is downloaded or installed until you click Update and Relaunch. [docs/UPDATES.md](docs/UPDATES.md) has the full rules and the feed format.

Every update must carry a minisign legacy Ed25519 ("Ed") signature over its `.sha256` file from the key paired with the update source. That check is mandatory and cannot be skipped. A source is a URL plus that key. The built-in source comes from `UPDATE_FEED_URL` and `UPDATE_PUBLIC_KEY` in `config/product.env`. A custom source entered in Settings is saved only as a validated HTTPS URL and key pair. A source without a key is never accepted, and a damaged custom source is reported as an error rather than replaced by another source.

The only install path is a signed zip holding the disk image, its `.sha256`, and its `.sha256.minisig`. The app downloads it over HTTPS (500 MB cap). Before extracting, it reads the zip's central directory and refuses path separators, `..`, symlinks, directories, extra or duplicate members, encryption, ZIP64, and local headers whose names differ from the central directory. It then extracts with `/usr/bin/ditto` into a fresh 0700 folder and checks the result again. The trusted comment (`version=… build=… commit=…`, optionally `file=…`) is parsed only from the verified signature. Its version, build, and commit must match the feed and the zip name, and the version must be strictly newer than the running app. Equal or older builds are refused, so a replayed or downgraded release does not install.

Stock `minisign -V` verifies this legacy "Ed" form. Signing with stock minisign requires `-l`. The app refuses a prehashed "ED" signature with the error: prehashed ED signatures are refused; sign with minisign -l (legacy Ed). The CI signer's key handling is described under Update signing key (CI) below.

Before the installed `.app` is replaced, `codesign --verify --deep --strict -R '=identifier "<bundle id>"'` must succeed and the bundle id inside Info.plist must match. Tools run with argument arrays, never through a shell. Ad-hoc builds satisfy that identifier requirement only. There is no Developer ID anchor. The new app is copied beside the installed one, and the old app is moved to a timestamped backup. The new app is checked again in place, and any failure after the first move puts the old app back. The new process deletes the backup only after it has launched.

## Update signing key (CI)

The private update-signing seed lives in a key file outside the checkout. The path comes from `UPDATE_SIGNING_KEY_FILE` and defaults to `~/Library/Application Support/WyvernBuild/update-signing.key`. The directory is mode 0700. The file is created with `open(O_CREAT|O_EXCL|O_NOFOLLOW, 0600)` and then `fchmod` to 0600, so it is never overwritten and umask cannot loosen or tighten it. `WyvernUpdateSigner` refuses a key file that is not a regular file owned by the build user with mode exactly 0600, or whose directory is not a real directory owned by the build user with no group or other access (`UPDATE_KEY_INSECURE`). It opens the file with `O_NOFOLLOW` and re-checks owner, mode, and identity on the open descriptor, and it refuses a path inside the checkout or `GITHUB_WORKSPACE` (`UPDATE_KEY_IN_WORKSPACE`).

CI reads only that file, so it never waits on a keychain dialog. The keychain is read in two cases only:

- Never by `--ensure`: a missing key file fails at once with `UPDATE_KEY_MISSING`. An unattended keychain read can leave a SecurityAgent dialog on screen that blocks the GUI tests, so migration is manual only.
- `--export-from-keychain`, run by hand once from a logged-in Terminal on the build Mac. It may show the keychain dialog (120 second limit), writes the key file, and prints `UPDATE_KEY_MIGRATED`. It refuses if the file already exists.
- `--keychain`, given explicitly with `--ensure` or `--sign`.

The signed trusted comment is `wyvern version=… build=… commit=… file=…`, built from the `--version`, `--build`, `--commit` and `--file` arguments and rejected by the same parser the app uses. The signer never generates a key. `--create-and-store` is refused. A seed whose public key is not the embedded release key (`UPDATE_PUBLIC_KEY` in `config/product.env`, also in Info.plist; a placeholder until you run `scripts/new-release-key.sh`) is refused with `UPDATE_KEY_MISMATCH`, so the pinned key cannot rotate without anyone noticing. A real rotation is a deliberate change to `config/product.env`, the signer constant, and every shipped app.

Every signer call in CI goes through `scripts/run-signer.sh`, which runs it under `perl -e 'alarm 60; exec @ARGV'` (macOS has no `timeout`). A call still running after 60 seconds is killed and reported as `SIGNING_TIMEOUT`, so a prompt fails the job instead of hanging it.

## Update sources

The app does not clone a repository and does not compile an update. Building from source with `scripts/build-app.sh` is a manual developer step. A release build never reads a git remote. Its Info.plist update URL comes only from `UPDATE_FEED_URL`, which must be empty or a plain `https://` URL that does not name a private or local host. Release builds refuse every `http://` source. Private-network HTTP sources exist only in builds compiled with `WYVERN_DEV_UPDATER`.

## Dev-channel updates

A dev-channel build can be compiled with `WYVERN_DEV_UPDATER=1` and `UPDATE_DEV_SOURCE=1` so its built-in feed may be a private-network `http://` URL (for example a self-hosted package registry on your LAN). Publish only minisign-signed zips to it; signature verification is the same as on a release build. To rotate the pinned public key, run `scripts/set-update-key.sh` (do not commit a signing seed).

## Terminal tabs

A terminal tab runs a command in the user's login shell. That uses a pseudo-terminal, which does not work under App Sandbox: a sandboxed child cannot reach the user's files or tools. Wyvern Browser ships non-sandboxed, with the hardened runtime, and is distributed outside the Mac App Store. The entitlements are microphone and camera only. The build does not disable library validation and does not allow JIT. `scripts/build-app.sh` signs with the hardened runtime. If this app is submitted to the Mac App Store, the terminal feature has to be removed.

The command is the string the user stored. It is one argument to the login shell. Page content, addresses, and import files never become a command. There is no URL scheme that starts a command, and the page script bridge does not start one. A bookmark does not run on import, on sync, on launch, or when an address is opened. Imported terminal bookmarks stay disabled until the user reviews them. The first run of a new or changed command asks, and a changed working directory or shell asks again. The dialog shows the command in full. The same text is the tab title. While a terminal tab is active, the address field shows the shell and the working directory.

Closing a terminal tab, or closing the window, stops the process group when a process is still running, and asks first. The bookmark file is mode 0600. The settings list warns that sharing or exporting that file shares the commands. The README states that these commands run with the user's privileges.
