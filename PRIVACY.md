# Privacy

Wyvern Browser collects nothing.

There is no account, no telemetry, no analytics, and no crash reporting. Bookmarks and settings stay on this Mac. The authors of Wyvern Browser do not receive a copy of the pages you open.

## Network

Wyvern Browser contacts the network for these reasons:

- loading a site you open in a tab
- fetching an icon for that site from the same host as the page
- optional network-health probes to the host of the visible tab (ICMP echo, then TCP connect on port 443 or 80)
- a manual update check that you start from the app menu or Settings

Network-health probes run about once a second while the window is visible, plus 30 seconds after it hides. Samples stay in an in-memory 60-second window and are not written to disk. No third-party endpoint is contacted. Settings can turn the feature off.

Update checks run only after you click Check for Updates…. They contact only the update source shown in Settings > Updates (and, for the download, the host its feed names), over HTTPS, with no cookies. Builds compiled with the developer updater flag may also use a private-network HTTP source; release builds cannot. The app never stores a token. A custom update source and its public key are kept in this Mac's user defaults.

Icon requests use an ephemeral session. A redirect that leaves the page host is refused. Wyvern Browser does not use a third-party icon service. The web view sends the same user agent as Safari on your Mac (WebKit's default plus Safari's `Version/x.y Safari/605.1.15`, read from the installed Safari). It adds no Wyvern-specific token, so sites see an ordinary Safari.

## Storage on this Mac

Bookmarks are a JSON file under Application Support for `com.example.wyvern`. Settings are stored in UserDefaults. Icons may be cached in memory and in that same Application Support folder. Downloaded files are written only to `~/Downloads` on this Mac (or a directory chosen with `--wyvern-downloads-dir`). The in-app download list stays in memory for the session and is not written to disk.

A first launch after the rename copies those files and settings from the previous Application Support folder when the new folder does not exist. `--wyvern-data-dir` skips that copy.

Clear Browsing Data removes site data kept by the system web view and deletes the icon cache. Bookmarks are kept. Delete All Bookmarks is a separate action and asks for confirmation first.

Site microphone and camera choices (Always allow / Always deny) are stored as JSON in that same Application Support folder. They never leave this Mac.

Terminal bookmarks are a separate JSON file, `terminal-bookmarks.json`, in that same folder. The file mode is 0600 (readable and writable only by you). The commands stay on this Mac. Nothing is uploaded, and importing bookmarks does not start a command.

## Bookmark import

Import reads bookmarks and folders only, on this Mac. Nothing is uploaded. Profiles are auto-detected where possible, then a confirm step lists the browser, profile name, and counts before anything is imported. History, favicons, cookies, logins, and form history are not read. Safari is detected only by folder presence; its bookmark file is never opened from this app. Extra privacy permissions are never requested in the background.
