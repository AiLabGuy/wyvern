// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Darwin
import Foundation

/// GUI acceptance checks. They run after the existing checks.
/// Each check records its own result and keeps going when an earlier one fails.
/// Each check starts from a new window (Command-N), or relaunches when that window does not appear.
extension UITestSession {
    private enum Key {
        static let a: CGKeyCode = 0
        static let q: CGKeyCode = 12
        static let w: CGKeyCode = 13
        static let t: CGKeyCode = 17
        static let two: CGKeyCode = 19
        static let five: CGKeyCode = 23
        static let i: CGKeyCode = 34
        static let returnKey: CGKeyCode = 36
        static let backslash: CGKeyCode = 42
        static let comma: CGKeyCode = 43
        static let n: CGKeyCode = 45
    }

    func runAcceptance(port: Int) {
        runSplitRight()
        runSplitShortcut()
        runSplitLayouts()
        runMixedLayout(port: port)
        runDevToolsOpen(port: port)
        runBlockList(port: port)
        runCleanup()
    }

    private func runSplitRight() {
        guard let ax = prepareFreshWindow() else {
            recordChecked("split-right", false, "no window")
            return
        }
        let path = activateSplitRight(ax)
        var count = paneSnapshots(ax).count
        let matched = waitUntil(6) {
            count = paneSnapshots(ax).count
            return count == 2
        }
        let bare = barePaneSnapshots(ax).count
        let ids = clip(paneSnapshots(ax).map(\.identifier) + barePaneSnapshots(ax).map(\.identifier))
        if matched {
            recordChecked("split-right", true, "panes=2 via \(path)")
        } else {
            recordChecked("split-right", false, "panes=\(count) bare=\(bare) ids=[\(ids)] via \(path)")
        }
    }

    private func runSplitShortcut() {
        guard let ax = prepareFreshWindow() else {
            recordChecked("split-shortcut", false, "no window")
            return
        }
        let start = paneSnapshots(ax).count
        let first = pressSplitShortcut(ax, previous: start)
        let second = pressSplitShortcut(ax, previous: first)
        let third = pressSplitShortcut(ax, previous: second)
        let toggled = first == 2 && second == 0 && third == 2
        recordChecked(
            "split-shortcut",
            toggled,
            "start=\(start) split=\(first) unsplit=\(second) split=\(third) bare=\(barePaneSnapshots(ax).count)"
        )
    }

    private func runSplitLayouts() {
        guard let ax = prepareFreshWindow() else {
            recordChecked("split-layouts", false, "no window")
            return
        }
        let roots = [
            ["View", "Split View", "Layout"],
            ["View", "Tiling", "Layout"]
        ]
        var layoutRoot: [String]?
        for root in roots {
            if let titles = ax.submenuTitles(path: root), !titles.isEmpty {
                layoutRoot = root
                break
            }
            ax.dismissMenu()
        }
        guard let layoutRoot else {
            recordChecked("split-layouts", false, "layout menu missing")
            return
        }
        let layouts: [(String, [String], Int)] = [
            ("2 Columns", ["2 Columns", "2 columns"], 2),
            ("2 Rows", ["2 Rows", "2 rows"], 2),
            ("3 Columns", ["3 Columns", "3 columns"], 3),
            ("2×2 Grid", ["2×2 Grid", "2x2 Grid", "2 by 2 grid"], 4),
            ("1 + 2", ["1 + 2", "1 plus 2"], 3)
        ]
        var parts: [String] = []
        var allPassed = true
        for layout in layouts {
            guard let window = prepareFreshWindow() else {
                parts.append("\(layout.0) no window")
                allPassed = false
                continue
            }
            let tabs = openTabs(window, total: 4)
            var pressError: String?
            for title in layout.1 {
                window.dismissMenu()
                if let error = window.pressMenu(path: layoutRoot + [title]) {
                    pressError = error
                    continue
                }
                pressError = nil
                break
            }
            var count = paneSnapshots(window).count
            if pressError == nil {
                _ = waitUntil(6) {
                    count = paneSnapshots(window).count
                    return count == layout.2
                }
            }
            let passed = pressError == nil && count == layout.2
            if !passed { allPassed = false }
            if let pressError {
                parts.append("\(layout.0) \(count)/\(layout.2) tabs=\(tabs) \(pressError)")
            } else {
                parts.append("\(layout.0) \(count)/\(layout.2) tabs=\(tabs)")
            }
        }
        recordChecked("split-layouts", allPassed, parts.joined(separator: "; "))
    }

    private func runMixedLayout(port: Int) {
        guard let initial = prepareFreshWindow() else {
            recordChecked("mixed-layout", false, "devtools tab missing; no window")
            recordChecked("mixed-terminal-web", false, "no window")
            return
        }
        let opened = ensureTerminalTab(initial)
        let ax = opened.client
        var notes: [String] = []
        if !opened.detail.isEmpty { notes.append(opened.detail) }
        let develop = ensureDevelopMenu(ax)
        if !develop.isEmpty { notes.append(develop) }
        if !focusNonTerminalTab(ax) {
            notes.append("web tab missing before load")
        }
        if !loadPath(ax, port: port, path: "/plain.html", titleNeedle: "Plain test page") {
            notes.append("web page did not load")
        }
        let splitNote = mixTerminalAndWeb(ax)
        if !splitNote.isEmpty { notes.append(splitNote) }
        ax.dismissMenu()
        _ = focusTab(ax) { blob($0).localizedCaseInsensitiveContains("Plain") || blob($0).contains("/plain.html") }
        if !ax.postChord(virtualKey: Key.i, flags: [.maskCommand, .maskAlternate]) {
            notes.append("could not post devtools shortcut")
        } else if waitUntil(8, { devToolsVisible(ax) }),
                  let devTab = tabSnapshots(ax).first(where: { self.isDevToolsTab($0) }) {
            if let add = ax.pressContextItem(identifier: devTab.identifier, title: "Add to Split") {
                let withCurrent = ax.pressContextItem(identifier: devTab.identifier, title: "Split with Current Tab")
                if let withCurrent {
                    notes.append(add + "; " + withCurrent)
                }
            }
        }
        if ax.hasBlockingUI() {
            _ = ax.clickLabeled("OK")
            pause(0.3)
        }
        let panes = paneValueSnapshots(ax)
        let values = kindValues(panes.snapshots)
        let hasDevTools = hasKind(values, "devtools")
        let hasTerminal = hasKind(values, "terminal")
        let hasWeb = hasKind(values, "web")
        let described = panes.snapshots.map { "\($0.identifier)=\($0.value)" }
        let summary = "values [\(values.joined(separator: ","))] panes [\(clip(described))] source=\(panes.source) \(notes.joined(separator: "; "))"
            .trimmingCharacters(in: .whitespaces)
        if hasDevTools && hasTerminal && hasWeb {
            recordChecked("mixed-layout", true, summary)
        } else if !hasDevTools {
            recordChecked("mixed-layout", false, "devtools tab missing; \(summary)")
        } else {
            recordChecked("mixed-layout", false, summary)
        }
        recordChecked("mixed-terminal-web", hasTerminal && hasWeb, summary)
    }

    private func runDevToolsOpen(port: Int) {
        guard let ax = prepareFreshWindow() else {
            recordChecked("devtools-open", false, "no window")
            return
        }
        var notes: [String] = []
        let develop = ensureDevelopMenu(ax)
        if !develop.isEmpty { notes.append(develop) }
        if !loadPath(ax, port: port, path: "/plain.html", titleNeedle: "Plain test page") {
            notes.append("web page did not load")
        }
        ax.dismissMenu()
        _ = focusTab(ax) { blob($0).localizedCaseInsensitiveContains("Plain") || blob($0).contains("plain.html") }
        if !ax.postChord(virtualKey: Key.i, flags: [.maskCommand, .maskAlternate]) {
            notes.append("could not post shortcut")
        }
        let opened = waitUntil(8) { devToolsVisible(ax) }
        let openTabsText = tabTitleDetail(ax)
        let container = ax.exists(identifier: "wyvern.devtools.container")
        if !ax.postChord(virtualKey: Key.i, flags: [.maskCommand, .maskAlternate]) {
            notes.append("could not post shortcut again")
        }
        let closed = waitUntil(6) { !devToolsVisible(ax) }
        if ax.hasBlockingUI() {
            _ = ax.clickLabeled("OK")
            pause(0.3)
        }
        let detail = "container=\(container) \(openTabsText) \(notes.joined(separator: "; "))"
            .trimmingCharacters(in: .whitespaces)
        if opened && closed {
            recordChecked("devtools-open", true, "toggled; \(detail)")
        } else if !opened {
            recordChecked("devtools-open", false, "no DevTools: tab or wyvern.devtools.container; \(detail)")
        } else {
            recordChecked("devtools-open", false, "second shortcut left it open; \(detail)")
        }
    }

    private func runBlockList(port: Int) {
        guard let ax = prepareFreshWindow() else {
            recordChecked("blocklist-count", false, "needs https fixture; no window")
            return
        }
        // A custom list URL has to be https. The fixture server is http on loopback,
        // so this check uses a launch argument or environment variable when the app has one.
        if let hook = blockListHook() {
            let value = hook.fileValue ? hostsFilePath() : "http://127.0.0.1:\(port)/test-hosts.txt"
            var arguments: [String] = []
            var environment: [String: String] = [:]
            if hook.environment {
                environment[hook.name] = value
            } else {
                arguments = [hook.name, value]
            }
            guard let launched = launchApp(extraArguments: arguments, extraEnvironment: environment) else {
                recordChecked("blocklist-count", false, "relaunch failed for \(hook.name)")
                return
            }
            let toggle = enableBlockMaster(launched)
            let loaded = loadPath(launched, port: port, path: "/blocked.html", titleNeedle: "Blocked test page")
            let reading = waitForBadge(launched)
            let toolbar = toolbarDump(launched)
            let detail = "count=\(reading.text) via \(hook.name) loaded=\(loaded) \(toggle) toolbar [\(toolbar)]"
            recordChecked("blocklist-count", loaded && (reading.count ?? 0) >= 1, detail)
            return
        }
        let settings = blockSettingsNote(ax)
        let loaded = loadPath(ax, port: port, path: "/blocked.html", titleNeedle: "Blocked test page")
        let reading = waitForBadge(ax)
        let toolbar = toolbarDump(ax)
        recordChecked(
            "blocklist-count",
            false,
            "needs https fixture; \(settings); loaded=\(loaded) badge=\(reading.text) toolbar [\(toolbar)]"
        )
    }

    private func runCleanup() {
        guard let ax = client, process?.isRunning == true else {
            record("cleanup", false, "app not running")
            return
        }
        var closed = 0
        var steps = 0
        while ax.exists(identifier: "wyvern.settings") && steps < 4 {
            steps += 1
            if ax.closeWindow(of: "wyvern.settings") {
                closed += 1
                pause(0.4)
            } else {
                break
            }
        }
        let settingsLeft = ax.exists(identifier: "wyvern.settings")
        activate()
        let posted = ax.postCommandKey(virtualKey: Key.q)
        if !posted {
            record("cleanup", false, "could not post quit; settingsLeft=\(settingsLeft)")
            return
        }
        var gone = waitUntil(5) { process?.isRunning != true }
        if !gone && ax.hasBlockingUI() {
            if !ax.clickLabeled("Close") {
                _ = ax.postKey(virtualKey: Key.returnKey, flags: [])
            }
            pause(0.4)
            gone = waitUntil(4) { process?.isRunning != true }
        }
        if gone {
            _ = client?.takeFrontmostIssue()
            record("cleanup", true, "settings closed \(closed); quit")
        } else {
            record("cleanup", false, "still running; settings closed \(closed); settingsLeft=\(settingsLeft)")
        }
    }

    private func prepareFreshWindow() -> AXClient? {
        if process?.isRunning != true || client == nil {
            guard let ax = launchApp() else { return nil }
            dismissOverlays(ax)
            return ax
        }
        guard let ax = client else { return nil }
        dismissOverlays(ax)
        activate()
        ax.dismissMenu()
        let before = ax.windowCount()
        if ax.postCommandKey(virtualKey: Key.n) {
            let grew = waitUntil(8) {
                if before == 0 {
                    return ax.exists(identifier: "wyvern.address")
                }
                return ax.windowCount() > before
            }
            if grew {
                // Command-N leaves the new window key. Close the others before clicking,
                // so the address-field click cannot raise the previous window.
                pause(0.3)
                ax.closeOtherWindows()
                pause(0.3)
                dismissOverlays(ax)
                if waitUntil(6, { ax.exists(identifier: "wyvern.address") && !ax.windowTitle().isEmpty }) {
                    _ = ax.takeFrontmostIssue()
                    return ax
                }
            }
        }
        guard let relaunched = launchApp() else { return nil }
        dismissOverlays(relaunched)
        return relaunched
    }

    private func launchApp(
        extraArguments: [String] = [],
        extraEnvironment: [String: String] = [:]
    ) -> AXClient? {
        terminateRunningApp()
        if dataDir.isEmpty {
            dataDir = "/tmp/wyvern-ui-\(UUID().uuidString)"
        }
        if downloadsDir.isEmpty {
            downloadsDir = "/tmp/wyvern-ui-dl-\(UUID().uuidString)"
        }
        if appBinary.isEmpty {
            return nil
        }
        do {
            try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: downloadsDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: appBinary)
        var arguments = [
            "--wyvern-data-dir", dataDir,
            "--wyvern-skip-engine-chooser",
            "--wyvern-window-size", "1360x830",
            "--wyvern-appearance", "light",
            "--wyvern-downloads-dir", downloadsDir
        ]
        arguments.append(contentsOf: extraArguments)
        launched.arguments = arguments
        if !extraEnvironment.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in extraEnvironment {
                environment[key] = value
            }
            launched.environment = environment
        }
        launched.standardOutput = FileHandle.nullDevice
        let errPath = dataDir + "/app-stderr.log"
        if !FileManager.default.fileExists(atPath: errPath) {
            FileManager.default.createFile(atPath: errPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: errPath) {
            _ = try? handle.seekToEnd()
            launched.standardError = handle
        } else {
            launched.standardError = FileHandle.nullDevice
        }
        do {
            try launched.run()
        } catch {
            return nil
        }
        process = launched
        let ax = AXClient(pid: launched.processIdentifier)
        client = ax
        activate()
        let ready = waitUntil(40) {
            ax.exists(identifier: "wyvern.address") && !ax.windowTitle().isEmpty
        }
        _ = ax.takeFrontmostIssue()
        return ready ? ax : nil
    }

    private func terminateRunningApp() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        self.process = nil
        client = nil
    }

    private func dismissOverlays(_ ax: AXClient) {
        if ax.exists(identifier: "wyvern.tour.skip") {
            _ = ax.clickIdentifier("wyvern.tour.skip")
            pause(0.3)
        }
        if ax.exists(identifier: "wyvern.sessionRestore.notNow") {
            _ = ax.clickIdentifier("wyvern.sessionRestore.notNow")
            pause(0.3)
        }
    }

    private func recordChecked(_ name: String, _ passed: Bool, _ detail: String) {
        if passed, let ax = client, ax.ensureFrontmost() == nil {
            _ = ax.takeFrontmostIssue()
        }
        record(name, passed, detail)
    }

    private func activateSplitRight(_ ax: AXClient) -> String {
        let paths = [
            ["View", "Split View", "Split Right"],
            ["View", "Tiling", "Split Right"],
            ["View", "Split Right"]
        ]
        var errors: [String] = []
        for path in paths {
            ax.dismissMenu()
            if let error = ax.pressMenu(path: path) {
                errors.append(error)
                continue
            }
            return path.joined(separator: " > ")
        }
        ax.dismissMenu()
        if ax.pressMenuItem(matching: "Split Right") {
            return "menu item containing Split Right"
        }
        if errors.isEmpty {
            return "Split Right missing"
        }
        return errors.joined(separator: "; ")
    }

    /// ⌃⌘\ toggles. Panes can show up one at a time, so the count has to sit still before it is read.
    private func pressSplitShortcut(_ ax: AXClient, previous: Int) -> Int {
        if !ax.postChord(virtualKey: Key.backslash, flags: [.maskCommand, .maskControl]) {
            return paneSnapshots(ax).count
        }
        var count = paneSnapshots(ax).count
        var unchanged = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            pause(0.25)
            let next = paneSnapshots(ax).count
            if next == count {
                unchanged += 1
                if next != previous && unchanged >= 2 {
                    return next
                }
                if unchanged >= 8 {
                    return next
                }
            } else {
                count = next
                unchanged = 0
            }
        }
        return paneSnapshots(ax).count
    }

    private func openTabs(_ ax: AXClient, total: Int) -> Int {
        var steps = 0
        while tabSnapshots(ax).count < total && steps < 6 {
            if !ax.postCommandKey(virtualKey: Key.t) { break }
            pause(0.45)
            steps += 1
        }
        return tabSnapshots(ax).count
    }

    private func ensureDevelopMenu(_ ax: AXClient) -> String {
        if ax.menuBarHasItem("Develop") {
            return ""
        }
        guard ax.postCommandKey(virtualKey: Key.comma) else { return "could not open settings" }
        guard waitUntil(8, { ax.exists(identifier: "wyvern.settings") }) else { return "settings did not open" }
        pause(0.3)
        showGeneral(ax)
        guard ax.exists(identifier: "wyvern.settings.showDevelopMenu") else {
            _ = ax.closeWindow(of: "wyvern.settings")
            return "showDevelopMenu missing"
        }
        let state = ax.switchIsOn(identifier: "wyvern.settings.showDevelopMenu")
        if state != true {
            _ = ax.clickIdentifier("wyvern.settings.showDevelopMenu")
            pause(0.4)
        }
        _ = ax.closeWindow(of: "wyvern.settings")
        _ = waitUntil(4) { !ax.exists(identifier: "wyvern.settings") }
        if waitUntil(4, { ax.menuBarHasItem("Develop") }) {
            _ = ax.clickIdentifier("wyvern.address")
            return ""
        }
        // An unreadable switch value may have been on. One more click turns it back on.
        if state == nil {
            _ = ax.postCommandKey(virtualKey: Key.comma)
            _ = waitUntil(6) { ax.exists(identifier: "wyvern.settings") }
            showGeneral(ax)
            if ax.exists(identifier: "wyvern.settings.showDevelopMenu") {
                _ = ax.clickIdentifier("wyvern.settings.showDevelopMenu")
                pause(0.4)
            }
            _ = ax.closeWindow(of: "wyvern.settings")
            if waitUntil(4, { ax.menuBarHasItem("Develop") }) {
                _ = ax.clickIdentifier("wyvern.address")
                return ""
            }
        }
        return "Develop menu hidden"
    }

    private func showGeneral(_ ax: AXClient) {
        _ = ax.postCommandKey(virtualKey: Key.two)
        if waitUntil(3, { ax.exists(identifier: "wyvern.settings.showDevelopMenu") }) {
            return
        }
        _ = ax.clickIdentifier("wyvern.settings.nav.general")
        _ = waitUntil(4) { ax.exists(identifier: "wyvern.settings.showDevelopMenu") }
    }

    private func ensureTerminalTab(_ ax: AXClient) -> (client: AXClient, detail: String) {
        var current = ax
        var reason = current.pressFirstTerminalItem()
        let needsBookmark = reason.contains("unavailable") || reason.contains("empty")
        if !reason.isEmpty && needsBookmark {
            seedTerminalBookmark()
            guard let relaunched = launchApp() else {
                return (current, "relaunch after terminal bookmark failed")
            }
            current = relaunched
            dismissOverlays(current)
            reason = current.pressFirstTerminalItem()
        }
        if !reason.isEmpty {
            return (current, reason)
        }
        if waitUntil(2, { current.hasBlockingUI() }) {
            _ = current.clickLabeled("Run")
            pause(0.4)
        }
        let appeared = waitUntil(6) { tabSnapshots(current).contains { self.isTerminalTab($0) } }
        if appeared {
            return (current, "")
        }
        return (current, "terminal tab missing")
    }

    /// Writes one enabled, already-confirmed bookmark so File > New Terminal Tab has a first item.
    private func seedTerminalBookmark() {
        guard !dataDir.isEmpty else { return }
        let url = URL(fileURLWithPath: dataDir).appendingPathComponent("terminal-bookmarks.json")
        let json = """
        {"version":1,"bookmarks":[{"id":"11111111-1111-1111-1111-111111111111","name":"Shell","command":"/bin/echo wyvern-ui-terminal","enabled":true,"confirmedCommandHash":"0d51524b69851796142e087b78fd6a94353dac7dbe92f3c39eed2da6759ccbed","workingDirectory":"","shell":"","openInNewTab":true}]}
        """
        try? json.data(using: .utf8)?.write(to: url)
        _ = url.path.withCString { chmod($0, 0o600) }
    }

    private func mixTerminalAndWeb(_ ax: AXClient) -> String {
        guard let web = tabSnapshots(ax).first(where: { !self.isTerminalTab($0) }) else {
            return "web tab missing"
        }
        guard let terminal = tabSnapshots(ax).first(where: { self.isTerminalTab($0) }) else {
            return "terminal tab missing"
        }
        _ = ax.clickIdentifier(web.identifier)
        pause(0.3)
        if ax.pressContextItem(identifier: terminal.identifier, title: "Split with Current Tab") == nil {
            return ""
        }
        if ax.pressContextItem(identifier: terminal.identifier, title: "Add to Split") == nil {
            return ""
        }
        if ax.pressContextItem(identifier: web.identifier, title: "Split with Current Tab") == nil {
            return ""
        }
        if ax.clickIdentifier("wyvern.toolbar.splitView") {
            return "split via toolbar"
        }
        return "could not mix terminal and web"
    }

    private func focusNonTerminalTab(_ ax: AXClient) -> Bool {
        focusTab(ax) { !isTerminalTab($0) }
    }

    @discardableResult
    private func focusTab(_ ax: AXClient, matching include: (AXSnapshot) -> Bool) -> Bool {
        guard let tab = tabSnapshots(ax).first(where: include) else { return false }
        return ax.clickIdentifier(tab.identifier)
    }

    private func loadPath(_ ax: AXClient, port: Int, path: String, titleNeedle: String) -> Bool {
        activate()
        guard ax.focusField(identifier: "wyvern.address") else { return false }
        pause(0.25)
        _ = ax.postCommandKey(virtualKey: Key.a)
        pause(0.05)
        guard ax.typeUnicode("127.0.0.1:\(port)\(path)") else { return false }
        pause(0.05)
        guard ax.postKey(virtualKey: Key.returnKey, flags: []) else { return false }
        return waitUntil(20) {
            let value = ax.value(identifier: "wyvern.address") ?? ""
            guard value.contains(path) else { return false }
            if titleNeedle.isEmpty { return true }
            if ax.windowTitle().contains(titleNeedle) { return true }
            return tabSnapshots(ax).contains { blob($0).contains(titleNeedle) }
        }
    }

    private func blockSettingsNote(_ ax: AXClient) -> String {
        guard ax.postCommandKey(virtualKey: Key.comma) else { return "settings closed" }
        guard waitUntil(8, { ax.exists(identifier: "wyvern.settings") }) else { return "settings did not open" }
        pause(0.3)
        var notes: [String] = []
        let panes: [(CGKeyCode, String)] = [
            (Key.two, "general"),
            (Key.five, "privacy")
        ]
        for pane in panes {
            _ = ax.postCommandKey(virtualKey: pane.0)
            pause(0.45)
            let ids = ax.identifiers { $0.lowercased().contains("block") }
            if !ids.isEmpty {
                notes.append("\(pane.1) [\(clip(ids))]")
            }
        }
        for identifier in blockNavIdentifiers(ax) where ax.clickIdentifier(identifier) {
            pause(0.45)
            let ids = ax.identifiers { $0.lowercased().contains("block") }
            if !ids.isEmpty {
                notes.append("\(identifier) [\(clip(ids))]")
            }
        }
        _ = ax.closeWindow(of: "wyvern.settings")
        _ = waitUntil(3) { !ax.exists(identifier: "wyvern.settings") }
        _ = ax.clickIdentifier("wyvern.address")
        if notes.isEmpty {
            return "no block-list control"
        }
        return notes.joined(separator: " ")
    }

    private func enableBlockMaster(_ ax: AXClient) -> String {
        guard ax.postCommandKey(virtualKey: Key.comma) else { return "settings closed" }
        guard waitUntil(8, { ax.exists(identifier: "wyvern.settings") }) else { return "settings did not open" }
        pause(0.3)
        let panes = [Key.two, Key.five]
        var clicked = ""
        for key in panes {
            _ = ax.postCommandKey(virtualKey: key)
            pause(0.4)
            let switches = ax.identifiers { id in
                let lower = id.lowercased()
                guard lower.contains("block") else { return false }
                return lower.contains("toggle") || lower.contains("enabled") || lower.contains("master") || lower.contains("switch")
            }
            for identifier in switches where ax.switchIsOn(identifier: identifier) != true {
                if ax.clickIdentifier(identifier) {
                    clicked = identifier
                    pause(0.3)
                }
            }
        }
        for identifier in blockNavIdentifiers(ax) where ax.clickIdentifier(identifier) {
            pause(0.4)
            let switches = ax.identifiers { id in
                let lower = id.lowercased()
                guard lower.contains("block") else { return false }
                return lower.contains("toggle") || lower.contains("enabled") || lower.contains("master") || lower.contains("switch")
            }
            for identifier in switches where ax.switchIsOn(identifier: identifier) != true {
                if ax.clickIdentifier(identifier) {
                    clicked = identifier
                    pause(0.3)
                }
            }
        }
        _ = ax.closeWindow(of: "wyvern.settings")
        _ = waitUntil(3) { !ax.exists(identifier: "wyvern.settings") }
        if clicked.isEmpty { return "no master toggle" }
        return "toggled \(clicked)"
    }

    /// Sidebar entries such as Settings > Block List, when that pane exists.
    private func blockNavIdentifiers(_ ax: AXClient) -> [String] {
        ax.identifiers { id in
            id.hasPrefix("wyvern.settings.nav.") && id.lowercased().contains("block")
        }
    }

    private struct BlockListHook {
        var name: String
        var environment: Bool
        var fileValue: Bool
    }

    private func blockListHook() -> BlockListHook? {
        guard !appBinary.isEmpty, let data = FileManager.default.contents(atPath: appBinary) else { return nil }
        let hooks: [(String, Bool)] = [
            ("--wyvern-block-list", false),
            ("--wyvern-blocklist-url", false),
            ("--wyvern-blocklist", false),
            ("--wyvern-custom-hosts", false),
            ("--wyvern-block-hosts", false),
            ("--wyvern-hosts-file", false),
            ("--wyvern-hosts", false),
            ("WYVERN_BLOCK_LIST", true),
            ("WYVERN_BLOCKLIST_URL", true),
            ("WYVERN_BLOCK_HOSTS", true),
            ("WYVERN_HOSTS_FILE", true),
            ("WYVERN_BLOCKLIST", true)
        ]
        let bytes = data as NSData
        for hook in hooks where dataContainsToken(bytes, hook.0) {
            let fileValue = hook.0.lowercased().contains("file") || hook.0.lowercased().contains("path")
            return BlockListHook(name: hook.0, environment: hook.1, fileValue: fileValue)
        }
        return nil
    }

    private func hostsFilePath() -> String {
        let path = (dataDir as NSString).appendingPathComponent("test-hosts.txt")
        let body = Data("0.0.0.0 ads.blocktest.localhost\n".utf8)
        FileManager.default.createFile(atPath: path, contents: body)
        return path
    }

    private func waitForBadge(_ ax: AXClient) -> (count: Int?, text: String) {
        var reading = badgeReading(ax)
        _ = waitUntil(12) {
            reading = badgeReading(ax)
            return (reading.count ?? 0) >= 1
        }
        reading = badgeReading(ax)
        return reading
    }

    private func badgeReading(_ ax: AXClient) -> (count: Int?, text: String) {
        let include: (String) -> Bool = { id in
            let lower = id.lowercased()
            return lower.contains("block") && lower.contains("badge")
        }
        var seen: Set<String> = []
        var ids: [String] = []
        for id in ax.focusedIdentifiers(matching: include) + ax.identifiers(matching: include) where seen.insert(id).inserted {
            ids.append(id)
        }
        var best: Int?
        var parts: [String] = []
        for id in ids {
            let text = ax.subtreeText(identifier: id)
            parts.append(text.isEmpty ? id : "\(id)=\(text)")
            if let number = firstInteger(in: text) {
                best = max(best ?? number, number)
            }
        }
        let text = parts.isEmpty ? "none" : parts.joined(separator: " ")
        return (best, text)
    }

    private func toolbarDump(_ ax: AXClient) -> String {
        var seen: Set<String> = []
        var ids: [String] = []
        let focused = ax.focusedIdentifiers { id in
            let lower = id.lowercased()
            return lower.contains("toolbar") || lower.contains("badge") || lower.contains("block")
        }
        let wide = ax.identifiers { id in
            let lower = id.lowercased()
            return lower.contains("block") || lower.contains("badge") || lower.contains("toolbar")
        }
        for id in focused + wide where seen.insert(id).inserted {
            ids.append(id)
        }
        if ids.isEmpty { return "none" }
        return clip(ids)
    }

    private func paneSnapshots(_ ax: AXClient) -> [AXSnapshot] {
        ax.focusedSnapshots { $0.hasPrefix("wyvern.tile.pane.") }
    }

    private func barePaneSnapshots(_ ax: AXClient) -> [AXSnapshot] {
        ax.focusedSnapshots { $0 == "wyvern.tile.pane" }
    }

    private func paneValueSnapshots(_ ax: AXClient) -> (source: String, snapshots: [AXSnapshot]) {
        let prefixed = paneSnapshots(ax)
        if !prefixed.isEmpty {
            return ("prefix", prefixed)
        }
        return ("bare", barePaneSnapshots(ax))
    }

    private func tabSnapshots(_ ax: AXClient) -> [AXSnapshot] {
        ax.focusedSnapshots { identifier in
            guard identifier.hasPrefix("wyvern.tab.") else { return false }
            let rest = identifier.dropFirst("wyvern.tab.".count)
            return !rest.isEmpty && rest.allSatisfy(\.isNumber)
        }
    }

    private func devToolsVisible(_ ax: AXClient) -> Bool {
        if ax.exists(identifier: "wyvern.devtools.container") { return true }
        return tabSnapshots(ax).contains { self.isDevToolsTab($0) }
    }

    private func isDevToolsTab(_ snap: AXSnapshot) -> Bool {
        snap.title.hasPrefix("DevTools:") || snap.label.hasPrefix("DevTools:") || snap.value.hasPrefix("DevTools:")
    }

    private func isTerminalTab(_ snap: AXSnapshot) -> Bool {
        let text = blob(snap).lowercased()
        return text.contains("terminal") || text.contains("wyvern-ui-terminal")
    }

    private func blob(_ snap: AXSnapshot) -> String {
        [snap.title, snap.label, snap.value].joined(separator: " ")
    }

    private func tabTitleDetail(_ ax: AXClient) -> String {
        let parts = tabSnapshots(ax).map { "\($0.identifier) title=\($0.title) label=\($0.label)" }
        if parts.isEmpty { return "tabs none" }
        return parts.joined(separator: "; ")
    }

    private func kindValues(_ snaps: [AXSnapshot]) -> [String] {
        snaps.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }

    private func hasKind(_ values: [String], _ kind: String) -> Bool {
        values.contains { value in
            if value == kind { return true }
            let parts = value.split { character in
                !character.isLetter && !character.isNumber
            }
            return parts.contains { String($0) == kind }
        }
    }

    private func firstInteger(in text: String) -> Int? {
        var digits = ""
        var started = false
        for character in text {
            if character.isNumber {
                digits.append(character)
                started = true
            } else if started {
                break
            }
        }
        guard started else { return nil }
        return Int(digits)
    }

    private func clip(_ items: [String]) -> String {
        let shown = items.prefix(8).joined(separator: ",")
        if items.count > 8 {
            return shown + ",..."
        }
        return shown
    }
}

private func dataContainsToken(_ data: NSData, _ token: String) -> Bool {
    guard let needle = token.data(using: .utf8), !needle.isEmpty else { return false }
    var offset = 0
    while offset < data.length {
        let found = data.range(
            of: needle,
            options: NSData.SearchOptions(rawValue: 0),
            in: NSRange(location: offset, length: data.length - offset)
        )
        if found.location == NSNotFound { return false }
        let beforeOK: Bool
        if found.location == 0 {
            beforeOK = true
        } else {
            var previous: UInt8 = 0
            data.getBytes(&previous, range: NSRange(location: found.location - 1, length: 1))
            beforeOK = !isTokenContinuation(previous)
        }
        let after = found.location + found.length
        let afterOK: Bool
        if after >= data.length {
            afterOK = true
        } else {
            var next: UInt8 = 0
            data.getBytes(&next, range: NSRange(location: after, length: 1))
            afterOK = !isTokenContinuation(next)
        }
        if beforeOK && afterOK { return true }
        offset = found.location + 1
    }
    return false
}

private func isTokenContinuation(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39)
        || (byte >= 0x41 && byte <= 0x5A)
        || (byte >= 0x61 && byte <= 0x7A)
        || byte == 0x5F
        || byte == 0x2D
}
