# Features

## Split view

A window shows one split group of 2, 3, or 4 panes. The layouts are 2 columns, 2 rows, 3 columns, a 2×2 grid, and 1 + 2 (a large pane on the left, two stacked on the right). Web tabs, terminal tabs, and a DevTools tab can share that group. The model test for a mixed group is `testMixedLayoutTerminalDevToolsAndWeb`.

### Mac acceptance: mixed layout

On a Mac, open a terminal tab and a web tab in one window and put them in a 2-column split. Confirm each pane shows its own content, the address bar follows the focused pane, and closing one pane leaves the other as a normal tab. A third pane can be a new-tab page: each pane in the split has its own new-tab page and its own bookmarks page. With Show Develop menu on, ⌥⌘I on the web pane adds a DevTools pane in the same split. The unit test above checks a three-column model with a terminal, a DevTools kind, and a web tab.

### Opening a split

The toolbar **Split View** button is 30×30, with the two-column glyph, immediately left of Downloads. A click splits the current tab with the most recent other tab into 2 columns. With only one tab, the right pane is a new-tab page. Press and hold for 300 ms to open the layout popover (five tiles, 44×30). The selected tile has a 2 px accent ring and an accessibility label such as "Layout: 2 columns, selected".

While the split is on screen, the glyph is tinted with the accent color and the button's fill stays clear. The tooltip and accessibility label read **Unsplit**. A click unsplits. A long-press still opens the layout popover and does not also unsplit.

The right-hand cluster is a horizontal stack: Split View, Downloads, then a hidden slot named `wyvern.toolbar.blockedBadge` for the blocked-count badge. Net-health stays pinned to the trailing edge of the toolbar. Downloads collapses out of the stack when there is nothing to show.

View > Split View holds the commands. They are not repeated on the Tab menu.

- **Split Right** (⌃⌘\\) adds a pane to the right, or unsplits when a split is already showing. Only one of Split Right and Unsplit All owns ⌃⌘\\ at a time.
- **Split Below** (⌃⌘⇧\\) adds a pane below.
- **Move Focus** (⌃⌘← / ⌃⌘→ / ⌃⌘↑ / ⌃⌘↓) moves to the neighbor pane.
- **Swap Left / Swap Right** (⌃⌘⇧← / ⌃⌘⇧→) exchanges the focused pane with that neighbor.
- **Equalize** (⌃⌘=) gives every pane an equal share.
- **Close Pane** (⌃⌘W) closes the focused pane's tab. ⌘W still closes the focused tab.
- **Unsplit All** returns the other panes to the tab strip, in tiled order, immediately after the focused tab.
- **Layout** switches among the five layouts. Extra slots open blank tabs. Slots that no longer fit return those tabs to the strip. The focused tab stays in the smaller layout: the slots are a window that contains it, so a focused tab at the end is not dropped. Tabs are not closed.
- **Move Focus** is also a submenu of the same directions.

While a DevTools tab is focused, ⌃⌥⌘ and the arrow keys move that pane (View > Move DevTools Left, Right, Above, and Below). The only other Control-Command shortcut in the app is Enter Full Screen (⌃⌘F).

The tab's context menu, after the existing items, offers **Split with Current Tab**, **Split Right**, **Split Below**, **Add to Split**, and **Remove from Split**. Add to Split is shown while a split exists. At 4 panes it is disabled, with the tooltip "Split View holds up to 4 tabs". Remove from Split is shown only for a tab that is already in the split. The tab strip has no Duplicate command and no multi-select, so **Tile N Tabs** is not offered.

Drag a tab from the strip onto the page. Within 25% of the left edge, the right edge, or the bottom edge, a drop preview appears after 150 ms: accent at 12% fill, a 2 px accent dashed outline, radius 8. The fade is 120 ms. Dropping tiles the tab even if the preview has not appeared yet. A release on the page that is not an edge target, and is more than 24 points from the tab strip, detaches the tab into a new window. A release closer to the strip than that, with no edge target, cancels. Esc cancels the drag, including a reorder in the strip. Dragging onto an existing pane's edge inserts next to that pane. The left and top edges place the tab on that side of the pane. Reduced motion shows the preview immediately and skips the fade.

Limits of that drag: moving a tab inside an existing split snaps the tree back to one of the five layouts. A drop does not replace a saved split that belongs to other tabs while those tabs are hidden, and no edge preview is drawn in that case. Split Below on the leading pane of a 2-pane split is refused, because the 1+2 layout cannot divide that pane; the preview is not shown, and Split Below on the other pane stacks the new tab on that pane's side. The preview is drawn from `mouseDragged`. If that event is not delivered, the preview stays hidden, and mouse-up still tiles when the pointer is in an edge zone that can accept the drop.

### Panes, dividers, and the tab strip

The focused pane has a 2 px accent ring, inset, that does not take clicks. With Increase Contrast, inactive panes get a 1 px line ring. The address bar, back, forward, reload, and the net-health badge follow the focused pane with no URL animation. Text already in the address field stays until Esc or Enter.

Each pane has a header pill at the top right (Make Main Tab, Close Pane). It appears after a 300 ms hover, while the pointer is in the top 48 px of the focused pane, or while the keyboard is inside the pane.

Dividers are a 1 px line with an 8 px hit area. Hover or drag thickens the line to 2 px accent over 120 ms. The cursor is resize-left-right or resize-up-down. Where two dividers cross, a 12×12 square uses a four-way cursor and drags both. Dragging snaps to 1/3, 1/2, and 2/3, within 8 px, with an alignment haptic and a short accent flash. A pane stops at 320 px wide and 200 px tall. Double-click equalizes that divider over 180 ms (immediately with reduced motion). Arrow keys move a focused divider 16 px, or 64 px with Shift. VoiceOver sees each divider as a splitter with a percent value.

If the window is too narrow for those minimums, the narrowest columns stack into rows for display only. The saved ratios return when the window is wide enough again. While a split is on screen, the window's minimum content width is the wider of 980 and `panes × 320 + dividers` (1304 for four panes). That minimum is written only when the requirement changes, so a resize does not reset it.

Tiled tabs sit together in the strip inside a capsule: 1 px accent at 45%, radius 9, inset 2 px. When the split is selected, the capsule uses the active-tab elevation. While a tab outside the split is selected, the members stay grouped with a quieter capsule fill. The focused member's title is full strength and the other members are at 75%. Each member shows a small split glyph before its favicon. With 3 or 4 members, those tabs are 140 px wide. Clicking a member selects the split and focuses that pane. Dragging a member out of the capsule removes it from the split and leaves the tab open. A new tab opens after the group, so it does not land between members.

Choosing a tab that is not in the split shows that tab alone and keeps the split saved. Choosing a member brings the split back. Closing a pane removes it. The last pane returns to a normal tab.

### Net health

One badge shows the focused pane's host. Each pane keeps its own samples, so focusing another pane and coming back does not start again at unknown. The badge crossfades over 200 ms. VoiceOver adds the pane, for example "Network: Fair, 164 milliseconds to example.com, right pane". The detail panel's Host row stays the focused host, with no pane suffix.

Unfocused visible panes are specified to probe every 6 seconds (`PaneProbeCadence.visibleUnfocused`). The prober still watches one host, the focused pane, at the existing 1 second interval. There is no second probe loop.

### Session restore

The split is saved with the window. A session saved before split view still opens. A damaged tile record does not drop the window's tabs. A saved DevTools tab is restored when its source page is restored with it. A DevTools-only window is not restored from disk. Replacing the terminal in a pane keeps the split and swaps in the new terminal.

## Develop menu

**Show Develop menu** is in **Settings > General**, in the **Develop** group. It is off until you turn it on. While it is off, the Develop menu is hidden and web pages are not inspectable. Turning it on or off applies to open pages immediately, and the menu appears or disappears with the switch.

The **Develop** menu is a top-level menu between View and History. Its commands use the focused web tab. A focused DevTools tab acts on its source page.

- **Show Web Inspector** (⌥⌘I) opens a DevTools tab for the focused page. The menu title is **Hide Web Inspector** while that tab is on screen. Pressing it again closes the DevTools tab and keeps the page. Pressing it while the DevTools tab is focused does the same. If the DevTools tab exists but is not on screen, ⌥⌘I brings it forward.
- **Start Element Selection** (⌥⌘C) opens or focuses that DevTools tab and asks WebKit to select an element.
- **Show JavaScript Console** (⌥⌘J) opens or focuses that DevTools tab and shows the console when WebKit provides that call.

The new-tab page, the bookmarks page, Settings, and terminal tabs stay closed to the inspector, and the commands are disabled on those tabs. ⌥⌘I does nothing on a DevTools tab that has no source page except to close it when that tab is focused.

With Show Develop menu on, a web page's context menu includes **Inspect Element**. Wyvern does not replace that menu. Choosing it opens the same DevTools tab. There is one DevTools tab per page.

The tab title is **DevTools: ** plus the page title. The prefix stays visible until the tab is narrower than 120 px, then the `{}` tile and the page title remain. Closing the page closes its DevTools tab. Closing DevTools leaves the page open. There is no recently-closed-tab stack, so ⌘⇧T does not reopen the pair. The title updates when the page title changes. Reload does not rename it.

An untiled page opens DevTools as a split: the page keeps the left 60% and DevTools the right 40%. Below an 800 px window width, DevTools opens on the bottom at 40%. If the page is already tiled and the split has fewer than four panes, DevTools takes a new pane on the right, 40% of the page pane's width. At four panes, the last pane that is not the page returns to the tab strip (it is not closed) and a toast offers Undo for 3 seconds. A later open in the same session uses the last side, including a standalone tab or its own window.

The DevTools tab's menu has Move (Left, Right, Above, or Below the page), Pop Out to Tab, Move to New Window, Reload Source, Show Source Tab, and Close DevTools. The pane pill has the same Move, Pop Out, and Close actions. Move to New Window is in the pill's overflow menu. A new window is 900×640, or the last frame stored under `wyvern.devtools.windowFrame`. While DevTools is a standalone tab or in its own window, the toolbar shows a **Linked to** chip for the page. Clicking it focuses that page. The address bar shows the page URL, read-only, with the `{}` tile.

Wyvern does not restyle the inspector. It tries to host WebKit's inspector inside the DevTools pane. If that fails, the pane says the inspector is open in its own window, and Show brings that window forward. The choice is logged as `WYVERN_DEVTOOLS_MODE=hosted` or `window`. Dock buttons inside the inspector are hidden with a style sheet whose class names can change between OS releases. If WebKit returns no inspector at all, an alert tells you to right-click the page and choose **Inspect Element**.

**Show Web Inspector** and **Show JavaScript Console** use a private WebKit interface. `WKWebView` has no public method that opens the inspector. Wyvern calls `_inspector`, then `show` or `showConsole`, and only after checking that the view responds to those selectors. If that interface is missing, a short alert tells you to right-click the page and choose **Inspect Element**.

## Block ads and trackers

Open Settings → Block List (the sidebar row after Privacy). The switch **Block ads and trackers** stays off until you turn it on, including after an upgrade. While it is off, the list and allowed-site cards dim but stay editable. VoiceOver says “Blocking is off” once when you turn the switch off.

While it is on, Wyvern downloads the lists you enable and blocks matching hosts in every tab. The built-in lists are:

- Ads & trackers (EasyList-compatible), from the StevenBlack unified hosts file
- Privacy trackers (EasyPrivacy-compatible), from the OISD small plain-domain list (`domainswild2`, one domain per line)

A leading `*.` is accepted. Adblock Plus filters are not. Two further lists from the design (cookie-banner annoyances, and malware & phishing domains) are not included: there is no verified hosts-format URL for them, and an Adblock Plus file would be rejected.

You can turn either list off, add your own HTTPS list (hosts format or one domain per line), rename or remove a custom list, and choose **Update Now**. A custom address must be HTTPS with no user name or password. Loopback, link-local, and local-only names (such as `localhost` or `*.local`) are refused. A private-network address is allowed only when you type that host, and a redirect may not move the download to a different private host. DNS that points a public name at a private address is not visible to this check. The list name comes from a `! Title:` or `# Title:` header when the file has one. Enabled lists refresh every 24 hours while blocking is on. Update Now and a list’s own menu still download when blocking is off, so the cache can be filled first. Downloads are stored under Application Support. A download or compile problem is shown on this pane and does not close the app. The last good copy stays in use.

International names are stored as punycode. A label that is still not ASCII is skipped, so one bad line cannot make WebKit reject the whole list. A name needs a dot, and the last label cannot be only digits, so a stray word or a bare `com` cannot block every `.com` host. A trailing dot on a request (`https://ads.example./path`) is still blocked. After an update that changes the filter format or how many rules fit in one list, Wyvern compiles again and does not keep the previous rules.

The toolbar shows a blocked-count badge on ordinary http and https pages, to the left of the network-health badge. It is on for those pages while blocking is on or View → Show Blocked Count is on (that menu item is on by default). Zero blocked requests still show the shield. The badge is hidden on the new-tab page, bookmarks, file pages, and terminal tabs. The Downloads button stays hidden until there is at least one download. The badge shows a shield and a count, **99+** past 99, with the exact count in the tooltip and for VoiceOver. Zero is the shield alone. Pause on a site shows **Paused**. Turning blocking off leaves the badge clickable, with a slashed shield. The count is for the focused tab’s current page load and resets when the main frame navigates. In a split, that tab is the focused pane, including when the strip’s selected tab is a different member. A terminal pane hides the badge. The count updates when pane focus changes.

WebKit does not report content-blocker hits, so the count is the number of page images, scripts, frames, and similar URLs whose hosts are on a list and not allowed. It does not see `fetch`, XHR, `sendBeacon`, CSS `url()`, or WebSockets. A `srcset` candidate can be counted even if it was never requested. Counts are unique URLs, not retries. A blocked main-frame navigation never runs the counter, and an in-page `pushState` does not reset it.

Click the badge for the count on that site, **Pause on this site**, and **Block List Settings…**. Pause adds the site to Allowed Sites (a leading `www.` is folded into the same host) and stays in sync with that list. **Reload** in the popover reloads the focused tab. Rules are installed immediately; open pages keep the previous rules until you reload. Settings shows **Reload pages to apply** for a few seconds, with **Reload All**. Cookie rules stay in effect at the same time.
