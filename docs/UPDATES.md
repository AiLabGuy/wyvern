# Updates

Wyvern Browser updates itself only when you ask: the app menu's **Check for Updates…** or the
**Check for Updates…** button in **Settings > Updates**. A check shows what is available, with
its version, build, and commit. Nothing is downloaded or installed until you click
**Update and Relaunch**.

Every update must carry a valid minisign signature from the public key paired with the update
source. That check is mandatory. There is no setting, flag, or prompt that skips it.

This page describes the feed format, what the app verifies, and how a fork hosts its own source.

## What happens on Update and Relaunch

1. Download the release zip named by the feed (HTTPS only, 500 MB cap, ephemeral session, no cookies).
2. Read the zip's central directory **before extracting anything**. Refuse it unless it holds exactly
   three root-level regular files: `<name>-<version>.dmg`, `<dmg>.sha256`, `<dmg>.sha256.minisig`.
   Path separators, `..`, absolute names, symlinks, directories, duplicates, encryption, ZIP64, and
   local headers whose names differ from the central directory are all refused.
3. Extract with `ditto -x -k` into a fresh 0700 temporary folder and check again that only those
   three regular files exist and nothing landed outside the folder.
4. Verify the minisign signature over the `.sha256` file with the source's key, including the
   global signature over the trusted comment.
5. Parse the **verified** trusted comment. Its version, build, and commit must match what the feed
   listed and the zip name, and the version must be strictly newer than the running app
   (marketing version first, then build). Equal or older is refused.
6. Check that the `.sha256` line names the disk image and matches its SHA-256.
7. Mount the image read-only, copy its single `.app` next to the installed app, and check
   `codesign --verify --deep --strict -R '=identifier "<bundle id>"'` plus the bundle id in its
   Info.plist.
8. Move the installed app to `<name>.app.backup-<timestamp>`, move the new app into place, and check
   its code signature again in place. Any failure puts the previous app back.
9. Relaunch with `/usr/bin/open -n <app>` (an argument array, never a shell). The new process
   deletes the backup after it starts.

Each refusal is shown in plain language, and details go to `update.log` in the app's data folder.

## Update source and key

An update source is a URL plus the minisign public key that must sign every update from it.

- **Built-in source**: `UPDATE_FEED_URL` and `UPDATE_PUBLIC_KEY` in `config/product.env`, baked
  into Info.plist as `App1UpdateFeedURL` and `App1UpdatePublicKey`.
- **Custom source**: entered in **Settings > Updates** and kept in user defaults. A URL and a key are
  always saved together. The URL must be `https://`, with no user name or password. The key must be
  a minisign public key: the 56-character line that starts with `RWQ`. You can also paste the whole
  `.pub` file. Settings shows the key ID the same way `minisign` prints it, so you can compare it
  with the one the source publishes. **Reset to Default** returns to the built-in source.

If a stored custom source becomes unusable (for example its key was removed), the app reports an
error. It does not quietly fall back to another source.

## Feed format: `latest.json` (format 1)

Serve this JSON object at the source URL:

```json
{
  "format": 1,
  "version": "0.2.0",
  "build": 42,
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "zip_url": "WyvernBrowser-0.2.0-b42.zip",
  "notes": "Optional plain text, shown before installing (first 400 characters)."
}
```

| Field | Rule |
| --- | --- |
| `format` | Must be `1`. A newer value tells the person to update by hand. |
| `version` | `CFBundleShortVersionString`: dot-separated numbers. |
| `build` | `CFBundleVersion`: a non-negative integer. |
| `commit` | 40 hex digits: the commit that was built. |
| `zip_url` | HTTPS URL of the release zip, or a path relative to the feed URL. The file name must be `<DMG_BASENAME>-<version>-b<build>.zip`. |
| `notes` | Optional. |

Unknown fields are ignored, so later fields can be added without breaking older apps. The feed
itself is not signed. Everything in it is checked against the signed trusted comment after download.
A feed can only offer a release that its key holder signed. It cannot lower the version, change
the commit, or swap the image.

### Release zip

`<DMG_BASENAME>-<version>-b<build>.zip` holds exactly these three files at its root:

- `<DMG_BASENAME>-<version>.dmg`: a disk image with one `.app` whose bundle id is the app's bundle id
- `<DMG_BASENAME>-<version>.dmg.sha256`: one line, `<64 hex>  <DMG_BASENAME>-<version>.dmg`
- `<DMG_BASENAME>-<version>.dmg.sha256.minisig`: a minisign **legacy** (`-l`, "Ed") signature over the `.sha256` file

The zip is used because some hosts (some forges' attachment endpoints, for example) refuse `.dmg` uploads.
CI and the app both use this one layout.

### Trusted comment

The minisign trusted comment holds `key=value` pairs separated by single spaces, in any order:

```
version=0.2.0 build=42 commit=0123456789abcdef0123456789abcdef01234567 file=WyvernBrowser-0.2.0.dmg
```

`version`, `build`, and `commit` are required. `file` is optional; if it is present, it must name the
disk image. A leading `wyvern ` token is accepted, and the project's CI writes it so that older
installs can still read the comment. Any other key, a repeated key, or extra spaces are refused.

## Gitea issue comments (alternative transport)

The source URL may instead be a Gitea API URL that returns issue comments, for example
`https://git.example.com/api/v1/repos/<owner>/<repo>/issues/<n>/comments`. The app takes the newest
`<DMG_BASENAME>-<version>-b<build>.zip` attachment (with an HTTPS download URL) from those comments.
If the comment body contains `commit <40 hex>`, the signed commit must match it. The same
verification steps apply. This is how the project's CI publishes builds. A static `latest.json` is
simpler for most forks.

## Default source: GitHub Releases

`config/product.env` ships with placeholders, not a working source:

```
UPDATE_FEED_URL=https://github.com/AiLabGuy/wyvern/releases/latest/download/latest.json
UPDATE_PUBLIC_KEY=<placeholder>
```

While either is a placeholder, `scripts/build-app.sh` warns and builds with no built-in source
(people can still set one in Settings > Updates). To publish signed releases from GitHub:

1. Run `bash scripts/new-release-key.sh`. It makes a fresh minisign key pair in `~/.minisign/`
   (outside the repo; `*.key` is gitignored anyway) and pins the public key in `config/product.env`
   and the other files that carry it. Commit those changes. Never commit the secret key.
2. In the GitHub repo, add the secrets `MINISIGN_SECRET_KEY` (the contents of
   `~/.minisign/wyvern-release.key`) and `MINISIGN_PASSWORD`.
3. Set `VERSION` in `config/product.env`, then push a matching tag (`v0.2.0`).
   `.github/workflows/release.yml` fills in `GITHUB_OWNER/GITHUB_REPO` from the repository, builds,
   signs, and uploads the zip and `latest.json` to the release.

`releases/latest/download/latest.json` redirects to a GitHub download host. The updater follows
HTTPS redirects to another host, and a relative `zip_url` resolves against the configured feed URL,
so the zip is fetched from `releases/latest/download/<zip>` too.

## Setting up your own source (forks)

1. **Make a key pair** with [minisign](https://jedisct1.github.io/minisign/):

   ```bash
   minisign -G -p wyvern-update.pub -s ~/.minisign/wyvern-update.key
   ```

   Keep the secret key off the web host, ideally on the build machine only (mode 0600).
   `App1UpdateSigner` does not generate a key. It signs only with the seed in
   `UPDATE_SIGNING_KEY_FILE` (default `~/Library/Application Support/WyvernBuild/update-signing.key`),
   which must be mode 0600 in a directory owned by the build user with no group or other access,
   and it refuses a seed whose public key is not `UPDATE_PUBLIC_KEY`. See [SECURITY.md](../SECURITY.md).
   A fork that chooses its own key signs with stock minisign, as below.

2. **Set your identity and key** in `config/product.env`: your own `BUNDLE_ID`, `DMG_BASENAME`,
   `UPDATE_PUBLIC_KEY` (the `RWQ…` line of `wyvern-update.pub`), and `UPDATE_FEED_URL`
   (for example `https://example.com/wyvern/latest.json`). Release builds reject an
   `UPDATE_FEED_URL` that is not plain `https://host/path`, or that names a private or `.local` host.

3. **Build and sign a release:**

   ```bash
   BUILD_NUMBER=42 bash scripts/build-app.sh
   bash scripts/make-dmg.sh                    # writes build/<name>-<version>.dmg and .sha256
   . scripts/load-product-env.sh
   dmg="${DMG_BASENAME}-${VERSION}.dmg"
   minisign -S -l -s ~/.minisign/wyvern-update.key -m "build/${dmg}.sha256" \
     -t "version=${VERSION} build=42 commit=$(git rev-parse HEAD) file=${dmg}"
   (cd build && zip -X -j "${DMG_BASENAME}-${VERSION}-b42.zip" "$dmg" "$dmg.sha256" "$dmg.sha256.minisig")
   ```

   `-l` is required. The app refuses prehashed ("ED") signatures. `BUILD_NUMBER` must increase with
   every release.

4. **Write `latest.json`** as shown above, with `"zip_url": "<DMG_BASENAME>-<version>-b42.zip"`.

5. **Check it before you publish:**

   ```bash
   swift run App1UpdateVerify --zip "build/${DMG_BASENAME}-${VERSION}-b42.zip" \
     --plist "build/${APP_BUNDLE}/Contents/Info.plist" \
     --feed latest.json --feed-url https://example.com/wyvern/latest.json
   ```

   It prints `UPDATE_VERIFY_OK` only if the app would accept the release.

6. **Upload** `latest.json` and the zip side by side to any HTTPS host: a static site, object storage,
   GitHub release assets (relative `zip_url`, feed URL `.../releases/latest/download/latest.json`),
   or a Gitea generic package, for example
   `https://gitea.example.com/api/packages/<owner>/generic/wyvern/latest/latest.json` with the zip
   uploaded to the same package version (re-upload `latest.json` there on each release; the package
   must be public). HTTPS redirects to another host (such as a
   download CDN) are followed. A redirect to plain HTTP is not.

People running a build made by someone else can point it at your source in **Settings > Updates**
by entering your feed URL and your public key. The new app must keep the same bundle id, or the
install step refuses it.

### Rotating a key

There is no in-band key rotation. To move to a new key, publish one last release signed with the old
key whose built-in `UPDATE_PUBLIC_KEY` is the new key. People using a custom source enter the new
key in Settings.

## Development sources

Builds compiled with `WYVERN_DEV_UPDATER` (`WYVERN_DEV_UPDATER=1 bash scripts/build-app.sh`, or the
Xcode Debug configuration) also accept `http://` sources on private IPv4 addresses (10/8,
172.16/12, 192.168/16), for a test server on a LAN. The built-in source needs `UPDATE_DEV_SOURCE=1`
as well. Release builds compile this out and refuse every `http://` source, whatever the settings.
Signature verification is the same in both.

### Dev channel (optional)

You can build a **dev-channel** app with `WYVERN_DEV_UPDATER=1`, `UPDATE_DEV_SOURCE=1`, and
`UPDATE_FEED_URL` set to a private-network feed, for example

`http://10.0.0.2:8080/wyvern-dev/latest.json`

Set `DEV_FEED_HOST` (for example `10.0.0.2`) when running `scripts/build-app.sh` so App Transport
Security allows plain HTTP to that host. Publish only the **signed** zip and `latest.json`; the
minisign check is mandatory and there is no unsigned feed. `scripts/set-update-key.sh` replaces the
pinned public key in `config/product.env`, Info.plist, the signer, and tests or docs that embed it.

## Limits

- Builds are ad-hoc signed. The code-signing check pins the bundle id, not a Developer ID. The
  minisign key is what establishes trust.
- Anything that can already write this user's defaults or replace files in the app's folder is
  outside what the updater can defend against.
- If a new version starts but misbehaves, the previous app stays beside it as
  `<name>.app.backup-<timestamp>` until the new version has launched once. After that, install an
  older release by hand.
