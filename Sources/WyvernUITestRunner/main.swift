// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import Darwin
import Foundation

private let grantSentence = "Grant it on the build Mac: System Settings > Privacy & Security > Accessibility > + > add the act_runner binary (the process that launches this job; its path is printed below), enable it, then re-run the job. If the runner is started from Terminal, add Terminal instead."

private let screenGrantSentence = "Grant it on the build Mac: System Settings > Privacy & Security > Screen Recording > + > add the act_runner binary (the process that launches this job; its path is printed below), enable it, then re-run the job. If the runner is started from Terminal, add Terminal instead."

private struct CheckResult {
    var name: String
    var passed: Bool
}

private final class UITestSession {
    private var process: Process?
    private var dataDir = ""
    private var downloadsDir = ""
    private var fixtureRoot = ""
    private var results: [CheckResult] = []
    private var client: AXClient?
    private var appBinary = ""

    func run() -> Int32 {
        requireSession()
        guard CommandLine.arguments.count >= 3 else {
            record("arguments", false, "usage WyvernUITestRunner APP_PATH BASE_URL [REPO_ROOT]")
            return finish(defaultCode: 1)
        }
        let appPath = CommandLine.arguments[1]
        let baseText = CommandLine.arguments[2]
        if CommandLine.arguments.count >= 4 {
            fixtureRoot = CommandLine.arguments[3]
        } else {
            fixtureRoot = FileManager.default.currentDirectoryPath
        }
        resetFailDirectory()
        guard let base = URL(string: baseText), let port = base.port, port > 0 else {
            record("arguments", false, "base URL needs a port")
            return finish(defaultCode: 1)
        }
        guard let binary = executablePath(inApp: appPath),
              FileManager.default.isExecutableFile(atPath: binary) else {
            record("launch", false, "application binary is missing")
            return finish(defaultCode: 1)
        }
        dataDir = "/tmp/wyvern-ui-\(UUID().uuidString)"
        downloadsDir = "/tmp/wyvern-ui-dl-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: downloadsDir, withIntermediateDirectories: true)
            let launched = Process()
            launched.executableURL = URL(fileURLWithPath: binary)
            launched.arguments = [
                "--wyvern-data-dir", dataDir,
                "--wyvern-skip-engine-chooser",
                "--wyvern-window-size", "1360x830",
                "--wyvern-appearance", "light",
                "--wyvern-downloads-dir", downloadsDir
            ]
            appBinary = binary
            launched.standardOutput = FileHandle.nullDevice
            let errPath = dataDir + "/app-stderr.log"
            FileManager.default.createFile(atPath: errPath, contents: nil)
            launched.standardError = FileHandle(forWritingAtPath: errPath) ?? FileHandle.nullDevice
            try launched.run()
            process = launched
        } catch {
            record("launch", false, "could not start the application")
            return finish(defaultCode: 1)
        }
        guard let process else {
            record("launch", false, "could not start the application")
            return finish(defaultCode: 1)
        }
        let ax = AXClient(pid: process.processIdentifier)
        client = ax
        activate()
        let launchStart = Date()
        let ready = waitUntil(40) {
            ax.exists(identifier: "wyvern.address") && !ax.windowTitle().isEmpty
        }
        if !ready {
            print("UI_DIAG launch-check elapsed=\(Int(Date().timeIntervalSince(launchStart)))s "
                + "address=\(ax.exists(identifier: "wyvern.address")) title=\"\(ax.windowTitle())\"")
        }
        // Activation while the process was still starting is not a test failure.
        _ = ax.takeFrontmostIssue()
        if ready {
            record("launch", true, "window ready")
        } else {
            record("launch", false, "window did not appear")
            let alive = process.isRunning
            print("UI_DIAG trusted=\(AXIsProcessTrusted()) appRunning=\(alive) "
                + (alive ? "" : "exit=\(process.terminationStatus) ") + ax.diagnostics())
            if let data = FileManager.default.contents(atPath: dataDir + "/app-stderr.log"),
               let text = String(data: data, encoding: .utf8) {
                let lines = text.split(separator: "\n").suffix(15)
                print("UI_DIAG app stderr (last \(lines.count) lines):")
                lines.forEach { print("  " + $0) }
            }
            return finish(defaultCode: 1)
        }
        runClickReplace(ax, port: port)
        runTabs(ax, port: port)
        runTabDragOut(ax, port: port)
        runAddressIterations(ax, port: port)
        runRetype(ax, port: port)
        runSearch(ax)
        runMedia(ax, port: port)
        runMediaCapture(ax, port: port)
        runDownloadFiles(ax, port: port)
        runBarSizes(ax)
        runBarCentering(ax)
        runNetHealth(ax, port: port)
        runSettingsToggles()
        runTerminalSettings()
        runSetupFlow()
        return finish(defaultCode: 1)
    }

    /// Close extra windows and tabs, then open one fresh tab and click the URL field.
    @discardableResult
    private func resetKnownState(_ ax: AXClient) -> Bool {
        activate()
        if ax.windowCount() == 0 {
            guard ax.postCommandKey(virtualKey: 45) else { blockEvents() }
            _ = waitUntil(10) { ax.exists(identifier: "wyvern.address") }
        }
        var steps = 0
        while ax.windowCount() > 1, steps < 12 {
            guard ax.postKey(virtualKey: 13, flags: [.maskCommand, .maskShift]) else { blockEvents() }
            pause(0.3)
            steps += 1
        }
        steps = 0
        while ax.countTabs() > 1, ax.windowCount() >= 1, steps < 40 {
            guard ax.postCommandKey(virtualKey: 13) else { blockEvents() }
            pause(0.25)
            steps += 1
        }
        if ax.windowCount() == 0 {
            guard ax.postCommandKey(virtualKey: 45) else { blockEvents() }
            _ = waitUntil(10) { ax.exists(identifier: "wyvern.address") }
        }
        activate()
        guard ax.postCommandKey(virtualKey: 17) else { blockEvents() }
        pause(0.45)
        if ax.countTabs() > 1 {
            activate()
            if ax.exists(identifier: "wyvern.tab.0.close") {
                _ = ax.clickIdentifier("wyvern.tab.0.close")
            } else if ax.moveToIdentifier("wyvern.tab.0"), ax.exists(identifier: "wyvern.tab.0.close") {
                _ = ax.clickIdentifier("wyvern.tab.0.close")
            } else {
                _ = ax.clickIdentifier("wyvern.tab.0")
                pause(0.2)
                _ = ax.postCommandKey(virtualKey: 13)
            }
            pause(0.35)
        }
        activate()
        _ = waitUntil(5) { ax.exists(identifier: "wyvern.address") }
        let focused = ax.focusField(identifier: "wyvern.address")
        pause(0.25)
        return focused
    }

    /// Type a URL and press Enter. The page is on the fixture server so a Mac with no
    /// outbound network can still prove the field submitted and the tab loaded it.
    private func runAddressIterations(_ ax: AXClient, port: Int) {
        _ = resetKnownState(ax)
        let typed = "127.0.0.1:\(port)/enter.html"
        for index in 1...10 {
            let name = "address-enter-\(index)"
            if index > 1 {
                guard ax.postCommandKey(virtualKey: 17) else { blockEvents() }
                pause(0.45)
            }
            activate()
            guard ax.focusField(identifier: "wyvern.address") else {
                record(name, false, "address field not found")
                continue
            }
            pause(0.25)
            guard ax.typeUnicode(typed) else { blockEvents() }
            pause(0.05)
            guard ax.postKey(virtualKey: 36, flags: []) else { blockEvents() }
            let loaded = waitUntil(20) {
                let value = ax.value(identifier: "wyvern.address") ?? ""
                return ax.windowTitle().contains("Entered test page")
                    && value.contains("127.0.0.1")
                    && value.contains("/enter.html")
            }
            let title = ax.windowTitle()
            let value = ax.value(identifier: "wyvern.address") ?? ""
            let tabReady = ax.exists(identifier: "wyvern.tab.\(index - 1)")
            if loaded && tabReady {
                record(name, true, "title contains Entered test page; address contains /enter.html")
            } else if !loaded {
                record(name, false, "entered page did not load (title \(title) address \(value))")
            } else {
                record(name, false, "missing tab wyvern.tab.\(index - 1)")
            }
        }
    }

    private func runRetype(_ ax: AXClient, port: Int) {
        _ = resetKnownState(ax)
        let expected = "http://127.0.0.1:\(port)/plain.html"
        let typed = "127.0.0.1:\(port)/plain.html"
        activate()
        guard ax.focusField(identifier: "wyvern.address") else {
            record("address-retype", false, "address field not found")
            record("address-select-all", false, "address field not found")
            return
        }
        pause(0.25)
        guard ax.postCommandKey(virtualKey: 0) else { blockEvents() }
        pause(0.1)
        guard ax.typeUnicode(typed) else { blockEvents() }
        pause(0.05)
        guard ax.postKey(virtualKey: 36, flags: []) else { blockEvents() }
        let titled = waitUntil(20) { ax.windowTitle().contains("Plain test page") }
        activate()
        guard ax.focusField(identifier: "wyvern.address") else {
            record("address-retype", false, "address field not found after load")
            record("address-select-all", false, "address field not found after load")
            return
        }
        pause(0.3)
        let value = ax.value(identifier: "wyvern.address") ?? ""
        if titled && value == expected {
            record("address-retype", true, "value \(expected); title Plain test page")
        } else {
            record("address-retype", false, "title \(ax.windowTitle()) value \(value)")
        }
        activate()
        guard ax.focusField(identifier: "wyvern.address") else {
            record("address-select-all", false, "address field not found")
            return
        }
        pause(0.25)
        guard ax.postCommandKey(virtualKey: 0) else { blockEvents() }
        let selectedOK = waitUntil(3) { ax.selectedText(identifier: "wyvern.address") == expected }
        let selected = ax.selectedText(identifier: "wyvern.address")
        if selectedOK {
            record("address-select-all", true, "selected text is the full URL")
        } else {
            record("address-select-all", false, "selected \(selected)")
        }
    }

    private func runSearch(_ ax: AXClient) {
        _ = resetKnownState(ax)
        activate()
        guard ax.focusField(identifier: "wyvern.address") else {
            record("search-query", false, "address field not found")
            return
        }
        pause(0.25)
        guard ax.postCommandKey(virtualKey: 0) else { blockEvents() }
        pause(0.1)
        guard ax.typeUnicode("wyvern ui test query") else { blockEvents() }
        pause(0.05)
        guard ax.postKey(virtualKey: 36, flags: []) else { blockEvents() }
        let matched = waitUntil(20) {
            searchLoaded(ax.value(identifier: "wyvern.address") ?? "")
        }
        let value = ax.value(identifier: "wyvern.address") ?? ""
        if matched {
            record("search-query", true, "host duckduckgo.com query present")
        } else {
            record("search-query", false, "network required; search page did not load (address \(value) title \(ax.windowTitle()))")
        }
    }

    /// Click the loaded URL, type over the selection, and prove the old URL is not still drawn.
    private func runClickReplace(_ ax: AXClient, port: Int) {
        let first = exerciseClickReplace(ax, port: port, round: 1)
        record("address-click-replace", first.passed, first.detail)
        activate()
        if replaceAddress(ax, with: "127.0.0.1:\(port)/frame.html") {
            _ = waitUntil(15) {
                ax.windowTitle().contains("Frame")
                    || (ax.value(identifier: "wyvern.address") ?? "").contains("frame.html")
            }
        }
        let second = exerciseClickReplace(ax, port: port, round: 2)
        record("address-click-replace-2", second.passed, second.detail)
    }

    private func exerciseClickReplace(_ ax: AXClient, port: Int, round: Int) -> (passed: Bool, detail: String) {
        let expected = "http://127.0.0.1:\(port)/plain.html"
        let typed = "127.0.0.1:\(port)/plain.html"
        let beforeName = round == 1 ? "address-before.png" : "address-before-\(round).png"
        let afterName = round == 1 ? "address-after-zzz.png" : "address-after-zzz-\(round).png"
        activate()
        guard replaceAddress(ax, with: typed) else {
            return (false, "could not load plain.html")
        }
        guard waitUntil(20, { ax.windowTitle().contains("Plain test page") }) else {
            return (false, "plain.html did not load (title \(ax.windowTitle()))")
        }
        activate()
        // 53 is Escape (kVK_Escape). Leave editing so the idle string is what the first capture shows.
        _ = ax.postKey(virtualKey: 53, flags: [])
        pause(0.3)
        let idle = ax.value(identifier: "wyvern.address") ?? ""
        guard idle == expected else {
            return (false, "idle value \(idle)")
        }

        var problems: [String] = []
        var sawText = ""
        if let failure = captureAddress(ax, name: beforeName) {
            problems.append("before: \(failureText(failure))")
        }
        activate()
        guard ax.clickIdentifier("wyvern.address") else {
            return (false, "could not click wyvern.address")
        }
        var selected = ax.selectedText(identifier: "wyvern.address")
        if selected != expected {
            selected = ax.selectedText(identifier: "wyvern.address")
        }
        if selected != expected {
            problems.append("selected \(selected) expected \(expected)")
        }
        guard ax.typeUnicode("zzz") else { blockEvents() }
        var value = ax.value(identifier: "wyvern.address") ?? ""
        if value != "zzz" {
            value = ax.value(identifier: "wyvern.address") ?? ""
        }
        if value != "zzz" {
            problems.append("value \(value)")
        }
        pause(0.4)
        if let failure = captureAddress(ax, name: afterName) {
            problems.append("after: \(failureText(failure))")
        } else if let report = analyzeAddress(afterName) {
            let pct = String(format: "%.1f", report.fraction * 100)
            sawText = "ocr \"\(report.text)\" ink \(report.inkedColumns)/\(report.width) (\(pct)%)"
            if !report.hasZZZ || report.hasLoopback || report.hasPlain || report.fraction >= 0.40 || report.fraction <= 0 {
                problems.append(sawText)
            }
        } else {
            problems.append("could not read \(afterName)")
        }
        activate()
        guard ax.postKey(virtualKey: 53, flags: []) else { blockEvents() }
        let restored = waitUntil(3) { ax.value(identifier: "wyvern.address") == expected }
        if !restored {
            problems.append("after escape value \(ax.value(identifier: "wyvern.address") ?? "")")
        }
        if problems.isEmpty {
            return (true, "selected full URL; value zzz; \(sawText); escape restored the URL")
        }
        return (false, problems.joined(separator: "; "))
    }

    private func captureAddress(_ ax: AXClient, name: String) -> FieldCaptureFailure? {
        let path = (artifactDirectory() as NSString).appendingPathComponent(name)
        let failure = FieldCapture.capture(rect: ax.frame(identifier: "wyvern.address"), to: path)
        if failure == nil {
            print("UI_ARTIFACT \(name)")
            fflush(stdout)
        }
        return failure
    }

    private func analyzeAddress(_ name: String) -> FieldImageReport? {
        let path = (artifactDirectory() as NSString).appendingPathComponent(name)
        switch FieldCapture.analyze(path: path) {
        case .success(let report):
            return report
        case .failure:
            return nil
        }
    }

    private func failureText(_ failure: FieldCaptureFailure) -> String {
        guard failure.permissionMissing else { return failure.detail }
        print("SCREEN_RECORDING_MISSING")
        print(screenGrantSentence)
        print(actRunnerPath().replacingOccurrences(
            of: "Add this binary in Accessibility:",
            with: "Add this binary in Screen Recording:"
        ))
        fflush(stdout)
        return failure.detail + " Screen Recording permission missing. " + screenGrantSentence
    }

    /// `RUNNER_TEMP/shots` is the folder the screenshot step zips onto the PR comment.
    private func artifactDirectory() -> String {
        let base: String
        if let temp = ProcessInfo.processInfo.environment["RUNNER_TEMP"], !temp.isEmpty {
            base = (temp as NSString).appendingPathComponent("shots")
        } else {
            base = "/tmp/wyvern-ui-shots"
        }
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    private func runTabs(_ ax: AXClient, port: Int) {
        let typed = "127.0.0.1:\(port)/plain.html"
        activate()
        guard replaceAddress(ax, with: typed) else {
            record("tabs-three", false, "could not load the first tab")
            return
        }
        _ = waitUntil(20) { ax.windowTitle().contains("Plain test page") }
        for _ in 1...2 {
            guard ax.postCommandKey(virtualKey: 17) else { blockEvents() }
            pause(0.45)
            activate()
            guard replaceAddress(ax, with: typed) else {
                record("tabs-three", false, "could not load a new tab")
                return
            }
            _ = waitUntil(20) { ax.windowTitle().contains("Plain test page") }
        }
        let three = waitUntil(5) { ax.countTabs() == 3 }
        if three {
            record("tabs-three", true, "three tabs")
        } else {
            record("tabs-three", false, "count \(ax.countTabs())")
            return
        }
        let activeBefore = ax.isSelected(identifier: "wyvern.tab.2")
        activate()
        guard ax.moveToIdentifier("wyvern.tab.1") else {
            record("tab-close-inactive", false, "could not hover tab 1")
            return
        }
        pause(0.35)
        guard ax.clickIdentifier("wyvern.tab.1.close") else {
            record("tab-close-inactive", false, "could not click the close button")
            return
        }
        let two = waitUntil(5) { ax.countTabs() == 2 }
        let activeSame = ax.isSelected(identifier: "wyvern.tab.1")
        if two && activeSame {
            record("tab-close-inactive", true, "count 2; active tab stayed")
        } else {
            record("tab-close-inactive", false, "count \(ax.countTabs()) selected-1 \(activeSame) was-2 \(activeBefore)")
        }
        activate()
        guard ax.postCommandKey(virtualKey: 13) else { blockEvents() }
        let one = waitUntil(5) { ax.countTabs() == 1 }
        if one {
            record("tab-close-key", true, "count 1 after Command-W")
        } else {
            record("tab-close-key", false, "count \(ax.countTabs())")
        }
        activate()
        guard ax.postCommandKey(virtualKey: 13) else { blockEvents() }
        let closed = waitUntil(5) { ax.windowCount() == 0 }
        let running = process?.isRunning == true
        if closed && running {
            record("tab-close-last", true, "window closed; process running")
        } else {
            record("tab-close-last", false, "windows \(ax.windowCount()) running \(running)")
        }
        activate()
        guard ax.postCommandKey(virtualKey: 45) else { blockEvents() }
        let restored = waitUntil(10) { ax.windowCount() >= 1 && ax.exists(identifier: "wyvern.address") }
        if restored {
            record("tab-new-window", true, "Command-N restored a window")
        } else {
            record("tab-new-window", false, "windows \(ax.windowCount())")
        }
    }

    /// Two tabs. Drag the second one down from its centre, with enough HID steps and
    /// pauses that AppKit sees the pointer leave the strip. The same tab opens in a
    /// second window; the first tab stays in the original window.
    private func runTabDragOut(_ ax: AXClient, port: Int) {
        _ = resetKnownState(ax)
        let typed = "127.0.0.1:\(port)/plain.html"
        activate()
        guard replaceAddress(ax, with: typed) else {
            record("tab-drag-out", false, "could not load the first tab")
            return
        }
        guard (waitUntil(20) { ax.windowTitle().contains("Plain test page") }) else {
            record("tab-drag-out", false, "first tab title \(ax.windowTitle())")
            return
        }
        guard ax.postCommandKey(virtualKey: 17) else { blockEvents() }
        pause(0.45)
        activate()
        guard (waitUntil(5) { ax.countTabs() == 2 && ax.exists(identifier: "wyvern.tab.1") }) else {
            record("tab-drag-out", false, "second tab missing count \(ax.countTabs())")
            return
        }
        let movedTitle = ax.label(identifier: "wyvern.tab.1") ?? ""
        guard !movedTitle.isEmpty, let frame = ax.frame(identifier: "wyvern.tab.1") else {
            record("tab-drag-out", false, "no label or frame for tab 1")
            return
        }
        // Centre of the tab. The close button is on the trailing edge; a point 48pt
        // from the leading edge can land on the badge or miss a narrow tab.
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let end = CGPoint(x: start.x, y: start.y + 150)
        guard ax.drag(from: start, to: end, steps: 28, stepPause: 0.05, target: "wyvern.tab.1") else {
            record("tab-drag-out", false, "could not drag tab 1")
            return
        }
        // Wait until the drag image is gone and the two browser windows show the split titles.
        // The new window is ordered front, so the focused title is the moved tab.
        let split = waitUntil(5) {
            ax.windowCount() == 2
                && ax.focusedWindowTitle().contains(movedTitle)
                && ax.windowTitles().contains { $0.contains("Plain test page") }
        }
        let titles = ax.windowTitles()
        let focused = ax.focusedWindowTitle()
        let newHasMoved = focused.contains(movedTitle)
        let keptPlain = titles.contains { $0.contains("Plain test page") }
        if split && newHasMoved && keptPlain {
            record("tab-drag-out", true, "windows 2; \"\(movedTitle)\" in \(focused)")
        } else {
            record(
                "tab-drag-out",
                false,
                "windows \(ax.windowCount()) focused \"\(focused)\" moved \"\(movedTitle)\" titles \(titles.joined(separator: " | "))"
            )
        }
    }

    private func runMedia(_ ax: AXClient, port: Int) {
        _ = resetKnownState(ax)
        let before = downloadFileNames()
        let target = "http://127.0.0.1:\(port)/media.html"
        activate()
        guard replaceAddress(ax, with: target) else {
            record("media-page", false, "could not type the media URL")
            return
        }
        let titled = waitUntil(20) { ax.windowTitle().contains("Media test page") }
        let deadline = Date().addingTimeInterval(5)
        var sawSheet = false
        var sawFile = false
        while Date() < deadline {
            if ax.hasBlockingUI() {
                sawSheet = true
            }
            if downloadFileNames().subtracting(before).isEmpty == false {
                sawFile = true
            }
            pause(0.25)
        }
        let sheetNow = ax.hasBlockingUI()
        if titled && !sawSheet && !sheetNow && !sawFile {
            record("media-page", true, "title Media test page; no sheet; no download file")
        } else {
            record(
                "media-page",
                false,
                "title \(ax.windowTitle()) sheet \(sawSheet || sheetNow) file \(sawFile)"
            )
        }
    }

    private func runMediaCapture(_ ax: AXClient, port: Int) {
        _ = resetKnownState(ax)
        let target = "http://127.0.0.1:\(port)/media-capture.html"
        activate()
        guard replaceAddress(ax, with: target) else {
            record("media-capture-deny", false, "could not type the capture URL")
            return
        }
        let titled = waitUntil(20) { ax.windowTitle().contains("Media capture test") }
        guard titled else {
            record("media-capture-deny", false, "page did not load (title \(ax.windowTitle()))")
            return
        }
        activate()
        pause(0.4)
        // The web AX tree is built lazily after load; wait until the button is exposed.
        _ = waitUntil(10) { ax.hasLabel("Start microphone") }
        // A real HID click on the page button is the user gesture getUserMedia needs.
        guard ax.clickLabeled("Start microphone") else {
            record("media-capture-deny", false, "Start microphone button not found or not clickable")
            return
        }
        // The app's prompt is a sheet on the browser window (AXSheets), also bridged into the bar.
        let prompt = waitUntil(10) {
            ax.exists(identifier: "wyvern.media.prompt")
                || ax.exists(identifier: "wyvern.mediaPrompt")
                || ax.exists(identifier: "wyvern.mediaPrompt.deny")
        }
        if prompt {
            guard ax.clickIdentifier("wyvern.mediaPrompt.deny") || ax.clickLabeled("Don't Allow") else {
                record("media-capture-deny", false, "Don't Allow was not clickable")
                return
            }
            let denied = waitUntil(10) { ax.windowTitle().contains("DENIED") }
            if denied {
                record("media-capture-deny", true, "prompt shown; Don't Allow; title DENIED")
            } else {
                record("media-capture-deny", false, "title \(ax.windowTitle())")
            }
            return
        }
        // WebKit can skip the in-app prompt when the capture has no user gesture.
        // The page title is the deny signal: DENIED passes, ALLOWED or no change fails.
        _ = waitUntil(8) {
            let title = ax.windowTitle()
            return title.contains("DENIED") || title.contains("ALLOWED")
        }
        let title = ax.windowTitle()
        if title.contains("DENIED") {
            record("media-capture-deny", true, "prompt did not appear; title DENIED")
        } else if title.contains("ALLOWED") {
            record("media-capture-deny", false, "title ALLOWED")
        } else {
            record("media-capture-deny", false, "permission prompt did not appear and title stayed \(title)")
        }
    }

    private func runDownloadFiles(_ ax: AXClient, port: Int) {
        _ = resetKnownState(ax)
        _ = waitForKeyWindow(ax)
        let fixture = (fixtureRoot as NSString).appendingPathComponent("tests-ui/fixtures/attach.bin")
        guard let expected = try? Data(contentsOf: URL(fileURLWithPath: fixture)) else {
            record("download-file", false, "fixture attach.bin is missing")
            record("download-unique", false, "fixture attach.bin is missing")
            record("download-popover", false, "fixture attach.bin is missing")
            return
        }
        let typed = "127.0.0.1:\(port)/attach.bin"
        activate()
        guard replaceAddress(ax, with: typed) else {
            record("download-file", false, "could not type the attachment URL")
            return
        }
        let firstPath = (downloadsDir as NSString).appendingPathComponent("attach.bin")
        let firstReady = waitUntil(10) { FileManager.default.isReadableFile(atPath: firstPath) }
        let firstBytes = (try? Data(contentsOf: URL(fileURLWithPath: firstPath))) ?? Data()
        let leftovers = leftoverPartials()
        let quarantined = hasQuarantine(firstPath)
        let button = waitUntil(3) { ax.exists(identifier: "wyvern.downloads.button") }
        if firstReady && firstBytes == expected && leftovers.isEmpty && quarantined && button {
            record("download-file", true, "attach.bin matches fixture; quarantined")
        } else {
            record(
                "download-file",
                false,
                "ready \(firstReady) bytes \(firstBytes.count) leftovers \(leftovers.count) quarantine \(quarantined) button \(button)"
            )
        }
        activate()
        guard replaceAddress(ax, with: typed) else {
            record("download-unique", false, "could not type the attachment URL again")
            return
        }
        // The app moves the finished `.download` file into place in one rename. Wait for the
        // full bytes, not only for the name, so a slow second transfer is not read early.
        let secondPath = (downloadsDir as NSString).appendingPathComponent("attach (1).bin")
        let secondReady = waitUntil(20) {
            (try? Data(contentsOf: URL(fileURLWithPath: secondPath))) == expected
        }
        let secondBytes = (try? Data(contentsOf: URL(fileURLWithPath: secondPath))) ?? Data()
        if secondReady && secondBytes == expected {
            record("download-unique", true, "attach (1).bin matches fixture")
        } else {
            let listing = downloadFileNames().sorted().joined(separator: ",")
            record("download-unique", false, "ready \(secondReady) bytes \(secondBytes.count) files [\(listing)]")
        }
        activate()
        guard ax.clickIdentifier("wyvern.downloads.button") else {
            record("download-popover", false, "could not open the downloads button")
            return
        }
        pause(0.4)
        let rows = waitUntil(3) {
            ax.exists(identifier: "wyvern.download.row.0") && ax.exists(identifier: "wyvern.download.row.1")
        }
        if rows {
            record("download-popover", true, "two download rows")
        } else {
            record("download-popover", false, "rows missing")
        }
    }

    private func replaceAddress(_ ax: AXClient, with text: String) -> Bool {
        activate()
        // Real CGEvent click in the middle of wyvern.address, the same path as address-click-replace.
        guard ax.clickIdentifier("wyvern.address") else { return false }
        pause(0.3)
        guard ax.postCommandKey(virtualKey: 0) else { blockEvents() }
        pause(0.1)
        guard ax.typeUnicode(text) else { blockEvents() }
        pause(0.05)
        guard ax.postKey(virtualKey: 36, flags: []) else { blockEvents() }
        return true
    }

    private func executablePath(inApp appPath: String) -> String? {
        let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        if let plist = NSDictionary(contentsOfFile: plistPath),
           let name = plist["CFBundleExecutable"] as? String {
            let path = (appPath as NSString).appendingPathComponent("Contents/MacOS/\(name)")
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        let folder = (appPath as NSString).appendingPathComponent("Contents/MacOS")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return items
            .map { (folder as NSString).appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func searchLoaded(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host?.lowercased() else { return false }
        let hostOK = host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com")
        let lower = value.lowercased()
        let queryOK = lower.contains("q=wyvern+ui+test+query") || lower.contains("q=wyvern%20ui%20test%20query")
        return hostOK && queryOK
    }

    private func requireSession() {
        let name = commandOutput(launchctlPath(), ["managername"])
        if name != "Aqua" {
            print("UI_TESTS_BLOCKED: no GUI session (runner must run as a LaunchAgent in the logged-in user session)")
            fflush(stdout)
            exit(2)
        }
        let session = (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
        let locked = sessionFlag(session, "CGSSessionScreenIsLocked")
        let onConsole = sessionFlag(session, kCGSessionOnConsoleKey as String)
        print("UI_SESSION locked=\(locked) onConsole=\(onConsole) sessionKeys=\(session.isEmpty ? 0 : session.count)")
        if locked || !onConsole {
            print("UI_TESTS_BLOCKED_SCREEN_LOCKED: the build Mac's login session is locked, asleep or not on the console (locked=\(locked) onConsole=\(onConsole)).")
            print("UI tests need the Mac awake and unlocked with the runner's user logged in at the console. They were NOT run; this is not a pass.")
            fflush(stdout)
            exit(4)
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options = NSDictionary(dictionary: [key: true]) // prompt: macOS shows the Accessibility dialog for the runner
        if !AXIsProcessTrustedWithOptions(options as CFDictionary) {
            print("UI_TESTS_BLOCKED: Accessibility permission missing.")
            print(grantSentence)
            print(actRunnerPath())
            fflush(stdout)
            exit(2)
        }
    }

    private func sessionFlag(_ session: [String: Any], _ key: String) -> Bool {
        if let value = session[key] as? Bool { return value }
        if let number = session[key] as? NSNumber { return number.boolValue }
        if let number = session[key] as? Int { return number != 0 }
        return false
    }

    private func blockEvents() -> Never {
        let passed = results.filter(\.passed).count
        let failed = results.count - passed
        print("UI_TESTS_PASSED=\(passed) UI_TESTS_FAILED=\(failed) UI_TESTS_TOTAL=\(results.count)")
        stopApp()
        print("UI_TESTS_BLOCKED: CGEvent posting failed.")
        print(grantSentence)
        print(actRunnerPath())
        fflush(stdout)
        exit(2)
    }

    /// Stoplight midlines match the bar. Address text ink is centered while the field editor is up.
    private func runBarCentering(_ ax: AXClient) {
        _ = resetKnownState(ax)
        _ = waitForKeyWindow(ax)
        pause(0.4)
        guard let bar = ax.frame(identifier: "wyvern.bar") else {
            record("traffic-center-buttons", false, "missing wyvern.bar")
            record("field-text-center", false, "missing wyvern.bar")
            return
        }
        var buttonOK = true
        var details: [String] = []
        for identifier in ["wyvern.traffic.close", "wyvern.traffic.min", "wyvern.traffic.zoom"] {
            guard let frame = ax.frame(identifier: identifier) else {
                buttonOK = false
                details.append("missing \(identifier)")
                continue
            }
            let delta = abs(frame.midY - bar.midY)
            if delta > 1 {
                buttonOK = false
            }
            details.append("\(identifier) mid \(frame.midY) bar \(bar.midY) delta \(delta)")
        }
        record("traffic-center-buttons", buttonOK, details.joined(separator: "; "))

        _ = waitForKeyWindow(ax)
        activate()
        guard ax.clickIdentifier("wyvern.address") else {
            record("field-text-center", false, "could not click wyvern.address")
            return
        }
        pause(0.2)
        guard ax.typeUnicode("Center") else { blockEvents() }
        pause(0.35)
        let value = ax.value(identifier: "wyvern.address") ?? ""
        guard value.contains("Center") else {
            record("field-text-center", false, "address value \(value)")
            return
        }
        guard let field = ax.frame(identifier: "wyvern.address") else {
            record("field-text-center", false, "missing address frame")
            return
        }
        let path = (artifactDirectory() as NSString).appendingPathComponent("address-vertical.png")
        if let failure = FieldCapture.capture(rect: field, to: path) {
            record("field-text-center", false, failureText(failure))
            return
        }
        print("UI_ARTIFACT address-vertical.png")
        fflush(stdout)
        switch FieldCapture.verticalInk(path: path) {
        case .failure(let message):
            record("field-text-center", false, message)
        case .success(let report):
            let delta = abs(report.inkMidY - Double(report.height) / 2)
            let limit = max(4.0, Double(report.height) * 0.12)
            let ok = report.inkedRows > 0 && delta <= limit
            record(
                "field-text-center",
                ok,
                String(format: "inkMid %.1f height %d delta %.1f limit %.1f rows %d", report.inkMidY, report.height, delta, limit, report.inkedRows)
            )
        }
        activate()
        guard ax.postKey(virtualKey: 53, flags: []) else { blockEvents() }
    }

    /// Walks the first-run window with real clicks, including one Back, then checks it does not return.
    private func runSetupFlow() {
        stopApp()
        let dir = "/tmp/wyvern-ui-setup-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            record("setup-welcome", false, "data dir")
            return
        }
        dataDir = dir
        func launch(showSetup: Bool) -> AXClient? {
            let launched = Process()
            launched.executableURL = URL(fileURLWithPath: appBinary)
            var args = [
                "--wyvern-data-dir", dir,
                "--wyvern-skip-engine-chooser",
                "--wyvern-window-size", "1360x830"
            ]
            if showSetup {
                args.append("--wyvern-show-setup")
            }
            launched.arguments = args
            launched.standardOutput = FileHandle.nullDevice
            launched.standardError = FileHandle.nullDevice
            do {
                try launched.run()
            } catch {
                return nil
            }
            process = launched
            dataDir = dir
            let ax = AXClient(pid: launched.processIdentifier)
            client = ax
            activate()
            return ax
        }
        guard let ax = launch(showSetup: true) else {
            record("setup-welcome", false, "launch")
            return
        }
        // Launch activation can leave a stale "not frontmost" issue. Drop it only on success.
        func passSetup(_ name: String, _ detail: String) {
            _ = client?.takeFrontmostIssue()
            record(name, true, detail)
        }
        let welcome = waitUntil(20) { ax.exists(identifier: "wyvern.setup.welcome") }
        guard welcome else {
            record("setup-welcome", false, "setup window did not appear")
            return
        }
        passSetup("setup-welcome", "welcome")
        activate()
        guard ax.clickIdentifier("wyvern.setup.next") else {
            record("setup-import", false, "could not click next")
            return
        }
        guard waitUntil(8, { ax.exists(identifier: "wyvern.setup.import") }) else {
            record("setup-import", false, "import step missing")
            return
        }
        activate()
        guard ax.clickIdentifier("wyvern.setup.back") else {
            record("setup-back", false, "could not click back")
            return
        }
        guard waitUntil(8, { ax.exists(identifier: "wyvern.setup.welcome") }) else {
            record("setup-back", false, "back did not return to welcome")
            return
        }
        passSetup("setup-back", "import to welcome")
        activate()
        guard ax.clickIdentifier("wyvern.setup.next") else {
            record("setup-import", false, "could not return to import")
            return
        }
        guard waitUntil(8, { ax.exists(identifier: "wyvern.setup.import") }) else {
            record("setup-import", false, "import did not return")
            return
        }
        var sawBrowser = false
        for index in 0..<12 where ax.exists(identifier: "wyvern.setup.browser.\(index)") {
            sawBrowser = true
        }
        passSetup("setup-import", sawBrowser ? "browser rows" : "no browser checkbox")
        activate()
        guard ax.clickIdentifier("wyvern.setup.next") else {
            record("setup-confirm", false, "could not leave import")
            return
        }
        let onAppearance = waitUntil(8) { ax.exists(identifier: "wyvern.setup.appearance") }
        guard onAppearance else {
            record("setup-confirm", false, "appearance did not follow import")
            return
        }
        passSetup(
            "setup-confirm",
            sawBrowser ? "import confirms in place" : "import confirms in place; no browser checkbox"
        )
        func pickAppearance(_ identifier: String, preference: String) -> Bool {
            activate()
            guard ax.clickIdentifier(identifier) else { return false }
            return waitUntil(5) {
                let stored = (ax.value(identifier: "wyvern.appearance.preference") ?? "").lowercased()
                return stored.contains(preference.lowercased())
            }
        }
        guard pickAppearance("wyvern.setup.appearance.light", preference: "light"),
              pickAppearance("wyvern.setup.appearance.dark", preference: "dark"),
              pickAppearance("wyvern.setup.appearance.system", preference: "system") else {
            record(
                "setup-appearance",
                false,
                "preference \(ax.value(identifier: "wyvern.appearance.preference") ?? "nil")"
            )
            return
        }
        passSetup(
            "setup-appearance",
            "light dark system preference \(ax.value(identifier: "wyvern.appearance.preference") ?? "")"
        )
        activate()
        guard ax.clickIdentifier("wyvern.setup.next") else {
            record("setup-latency", false, "could not open latency")
            return
        }
        guard waitUntil(8, { ax.exists(identifier: "wyvern.setup.latency") }) else {
            record("setup-latency", false, "latency step missing")
            return
        }
        let badgeBefore = ax.exists(identifier: "wyvern.netHealth.badge")
        activate()
        guard ax.clickIdentifier("wyvern.setup.latency.toggle") else {
            record("setup-latency", false, "could not click the latency toggle")
            return
        }
        let badgeHid = badgeBefore && waitUntil(5) { !ax.exists(identifier: "wyvern.netHealth.badge") }
        activate()
        guard ax.clickIdentifier("wyvern.setup.latency.toggle") else {
            record("setup-latency", false, "could not click the latency toggle again")
            return
        }
        if badgeHid {
            guard waitUntil(5, { ax.exists(identifier: "wyvern.netHealth.badge") }) else {
                record("setup-latency", false, "badge stayed hidden")
                return
            }
        }
        passSetup("setup-latency", badgeHid ? "badge hidden then shown" : "toggle clicked")
        activate()
        guard ax.clickIdentifier("wyvern.setup.next") else {
            record("setup-done", false, "could not open done")
            return
        }
        guard waitUntil(8, { ax.exists(identifier: "wyvern.setup.done") }) else {
            record("setup-done", false, "done step missing")
            return
        }
        activate()
        guard ax.clickIdentifier("wyvern.setup.next") else {
            record("setup-done", false, "could not finish")
            return
        }
        let closed = waitUntil(8) {
            !ax.exists(identifier: "wyvern.setup.window")
                && !ax.exists(identifier: "wyvern.setup.done")
                && !ax.exists(identifier: "wyvern.setup.welcome")
                && ax.windowCount() > 0
        }
        guard closed else {
            record("setup-done", false, "setup window stayed open")
            return
        }
        guard let process else {
            record("setup-done", false, "process missing")
            return
        }
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
        guard let again = launch(showSetup: false) else {
            record("setup-done", false, "relaunch")
            return
        }
        let quiet = waitUntil(20) {
            !again.exists(identifier: "wyvern.setup.window")
                && !again.exists(identifier: "wyvern.setup.welcome")
                && again.windowCount() > 0
        }
        if quiet {
            passSetup("setup-done", "closed and did not return")
        } else {
            record("setup-done", false, "setup returned on relaunch")
        }
    }

    private func runBarSizes(_ ax: AXClient) {
        _ = resetKnownState(ax)
        _ = waitForKeyWindow(ax)
        pause(0.4)
        func check(_ id: String, height: CGFloat, tolerance: CGFloat, minWidth: CGFloat, name: String) {
            guard let frame = ax.frame(identifier: id) else {
                record(name, false, "missing \(id)")
                return
            }
            let ok = abs(frame.height - height) <= tolerance && frame.width + 0.5 >= minWidth
            if ok {
                record(name, true, "h=\(frame.height) w=\(frame.width)")
            } else {
                record(name, false, "h=\(frame.height) w=\(frame.width) expected h~\(height)")
            }
        }
        check("wyvern.bar", height: 38, tolerance: 1, minWidth: 200, name: "bar-sizes-bar")
        check("wyvern.address", height: 32, tolerance: 2, minWidth: 80, name: "bar-sizes-url")
        check("wyvern.tab.0", height: 30, tolerance: 2, minWidth: 40, name: "bar-sizes-tab")
        if let back = ax.frame(identifier: "wyvern.back") {
            let ok = back.width >= 28 && back.height >= 28
            record("bar-sizes-back", ok, "\(Int(back.width))x\(Int(back.height))")
        } else {
            record("bar-sizes-back", false, "missing wyvern.back")
        }
        activate()
        _ = ax.moveToIdentifier("wyvern.tab.0")
        pause(0.35)
        if let close = ax.frame(identifier: "wyvern.tab.0.close") {
            let ok = close.width >= 28 && close.height >= 28
            record("bar-sizes-close", ok, "\(Int(close.width))x\(Int(close.height))")
        } else {
            record("bar-sizes-close", false, "missing close")
        }
        let all = results.filter { $0.name.hasPrefix("bar-sizes") }
        let passed = all.allSatisfy(\.passed)
        record("bar-sizes", passed, passed ? "metrics" : "see bar-sizes-*")
    }

    private func runNetHealth(_ ax: AXClient, port: Int) {
        _ = resetKnownState(ax)
        _ = waitForKeyWindow(ax)
        let target = "http://127.0.0.1:\(port)/"
        activate()
        guard replaceAddress(ax, with: target) else {
            record("net-health-good", false, "could not load loopback")
            return
        }
        let good = waitUntil(10) {
            let label = ax.label(identifier: "wyvern.netHealth.badge") ?? ""
            return label.contains("Good")
        }
        if !good {
            record("net-health-good", false, "label=\(ax.label(identifier: "wyvern.netHealth.badge") ?? "missing")")
            return
        }
        activate()
        guard ax.clickIdentifier("wyvern.netHealth.badge") else {
            record("net-health-good", false, "could not open panel")
            return
        }
        pause(0.4)
        let panel = ax.exists(identifier: "wyvern.netHealth.panel")
        let kindText = (ax.label(identifier: "wyvern.netHealth.probeKind") ?? "")
            + (ax.value(identifier: "wyvern.netHealth.probeKind") ?? "")
            + (ax.label(identifier: "wyvern.netHealth.panel") ?? "")
        let showsKind = kindText.contains("ICMP") || kindText.contains("TCP") || ax.exists(identifier: "wyvern.netHealth.trace")
        if panel && showsKind {
            record("net-health-good", true, "Good + probe panel")
        } else {
            record("net-health-good", false, "panel=\(panel) kind=\(kindText)")
        }
        activate()
        _ = ax.postKey(virtualKey: 53, flags: [])
    }

    private func runSettingsToggles() {
        stopApp()
        let dir = "/tmp/wyvern-ui-settings-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            record("settings-toggles", false, "data dir")
            return
        }
        func launch(keepAppearance: Bool) -> AXClient? {
            let launched = Process()
            launched.executableURL = URL(fileURLWithPath: appBinary)
            var args = [
                "--wyvern-data-dir", dir,
                "--wyvern-skip-engine-chooser",
                "--wyvern-window-size", "1360x830"
            ]
            if keepAppearance {
                args.append(contentsOf: ["--wyvern-appearance", "light"])
            }
            launched.arguments = args
            launched.standardOutput = FileHandle.nullDevice
            launched.standardError = FileHandle.nullDevice
            do {
                try launched.run()
            } catch {
                return nil
            }
            process = launched
            dataDir = dir
            let ax = AXClient(pid: launched.processIdentifier)
            client = ax
            activate()
            let ready = waitUntil(20) {
                ax.exists(identifier: "wyvern.address") && !ax.windowTitle().isEmpty
            }
            _ = ax.takeFrontmostIssue()
            return ready ? ax : nil
        }
        guard let ax = launch(keepAppearance: false) else {
            record("settings-toggles", false, "first launch")
            return
        }
        let first = waitUntil(5) { ax.value(identifier: "wyvern.appearance") == "dark" }
        if !first {
            record("settings-toggles", false, "fresh appearance \(ax.value(identifier: "wyvern.appearance") ?? "nil")")
            return
        }
        activate()
        guard ax.postCommandKey(virtualKey: 43) else { blockEvents() }
        let settingsOpen = waitUntil(8) { ax.exists(identifier: "wyvern.settings") || ax.exists(identifier: "wyvern.settings.lightAppearance") }
        if !settingsOpen {
            record("settings-toggles", false, "settings did not open")
            return
        }
        pause(0.3)
        guard ax.clickIdentifier("wyvern.settings.lightAppearance") else {
            record("settings-toggles", false, "could not toggle light")
            return
        }
        pause(0.4)
        let light = waitUntil(5) { ax.value(identifier: "wyvern.appearance") == "light" }
        if !light {
            record("settings-toggles", false, "after toggle \(ax.value(identifier: "wyvern.appearance") ?? "nil")")
            return
        }
        activate()
        guard ax.postCommandKey(virtualKey: 12) else { blockEvents() }
        _ = waitUntil(8) { process?.isRunning != true }
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        process = nil
        dataDir = ""
        guard let ax2 = launch(keepAppearance: false) else {
            record("settings-toggles", false, "relaunch")
            return
        }
        let persisted = waitUntil(5) { ax2.value(identifier: "wyvern.appearance") == "light" }
        if !persisted {
            record("settings-toggles", false, "relaunch appearance \(ax2.value(identifier: "wyvern.appearance") ?? "nil")")
            return
        }
        activate()
        guard ax2.postCommandKey(virtualKey: 43) else { blockEvents() }
        _ = waitUntil(8) { ax2.exists(identifier: "wyvern.settings.hideWebTabs") }
        pause(0.3)
        guard ax2.clickIdentifier("wyvern.settings.hideWebTabs") else {
            record("settings-toggles", false, "hide web")
            return
        }
        pause(0.3)
        let terminalEnabled = ax2.isEnabled(identifier: "wyvern.settings.hideTerminalTabs")
        _ = ax2.clickIdentifier("wyvern.settings.hideWebTabs")
        if persisted && !terminalEnabled {
            record("settings-toggles", true, "dark default, light persisted, hide coupling")
        } else {
            record("settings-toggles", terminalEnabled == false, "terminalEnabled=\(terminalEnabled)")
        }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Settings > Terminal hosts the bookmark editor. Command-4 selects that pane when Settings is key.
    private func runTerminalSettings() {
        stopApp()
        let dir = "/tmp/wyvern-ui-terminal-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            record("terminal-bookmarks", false, "data dir")
            return
        }
        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: appBinary)
        launched.arguments = [
            "--wyvern-data-dir", dir,
            "--wyvern-skip-engine-chooser",
            "--wyvern-window-size", "1360x830"
        ]
        launched.standardOutput = FileHandle.nullDevice
        launched.standardError = FileHandle.nullDevice
        do {
            try launched.run()
        } catch {
            record("terminal-bookmarks", false, "launch")
            return
        }
        process = launched
        dataDir = dir
        let ax = AXClient(pid: launched.processIdentifier)
        client = ax
        activate()
        let ready = waitUntil(20) {
            ax.exists(identifier: "wyvern.address") && !ax.windowTitle().isEmpty
        }
        _ = ax.takeFrontmostIssue()
        guard ready else {
            record("terminal-bookmarks", false, "window")
            try? FileManager.default.removeItem(atPath: dir)
            return
        }
        activate()
        guard ax.postCommandKey(virtualKey: 43) else { blockEvents() }
        let settingsOpen = waitUntil(8) { ax.exists(identifier: "wyvern.settings") }
        if !settingsOpen {
            record("terminal-bookmarks", false, "settings did not open")
            try? FileManager.default.removeItem(atPath: dir)
            return
        }
        pause(0.3)
        activate()
        // ANSI 4. selectTabByNumber routes Command-4 to the Terminal pane while Settings is key.
        guard ax.postCommandKey(virtualKey: 21) else { blockEvents() }
        let pane = waitUntil(8) {
            ax.exists(identifier: "wyvern.settings.terminal.add")
                && ax.exists(identifier: "wyvern.settings.nav.terminal")
        }
        if !pane {
            record("terminal-bookmarks", false, "terminal pane")
            try? FileManager.default.removeItem(atPath: dir)
            return
        }
        activate()
        guard ax.clickIdentifier("wyvern.settings.terminal.add") else {
            record("terminal-bookmarks", false, "add")
            try? FileManager.default.removeItem(atPath: dir)
            return
        }
        let editor = waitUntil(8) { ax.exists(identifier: "wyvern.terminal.editor") }
        if !editor {
            record("terminal-bookmarks", false, "editor")
            try? FileManager.default.removeItem(atPath: dir)
            return
        }
        activate()
        guard ax.clickIdentifier("wyvern.terminal.editor.cancel") else {
            record("terminal-bookmarks", false, "cancel")
            try? FileManager.default.removeItem(atPath: dir)
            return
        }
        let closed = waitUntil(5) { !ax.exists(identifier: "wyvern.terminal.editor") }
        record("terminal-bookmarks", closed, closed ? "add then cancel" : "editor stayed open")
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func finish(defaultCode: Int32) -> Int32 {
        stopApp()
        let passed = results.filter(\.passed).count
        let failed = results.count - passed
        print("UI_TESTS_PASSED=\(passed) UI_TESTS_FAILED=\(failed) UI_TESTS_TOTAL=\(results.count)")
        fflush(stdout)
        if failed == 0 && !results.isEmpty {
            return 0
        }
        return defaultCode
    }

    /// A check that needed the app frontmost and did not get it fails with "not frontmost".
    private func record(_ name: String, _ passed: Bool, _ detail: String) {
        var passed = passed
        var detail = detail
        if let issue = client?.takeFrontmostIssue() {
            passed = false
            detail += "; " + issue
        }
        results.append(CheckResult(name: name, passed: passed))
        let status = passed ? "PASS" : "FAIL"
        let clean = redact(detail.replacingOccurrences(of: "\n", with: " "))
        print("UI_TEST \(name) \(status) \(clean)")
        if !passed {
            diagnose(name)
        }
        fflush(stdout)
    }

    /// `UI_DIAG <test> ...` lines: the last targeted element's AX dump, the click point, the
    /// frontmost app and key window, and a capture of each app window in build/ui-fail.
    private func diagnose(_ name: String) {
        guard let ax = client else { return }
        var lines: [String] = []
        if let target = ax.lastTarget {
            lines.append(ax.describe(target: target))
        } else {
            lines.append("target none")
        }
        if let point = ax.lastPoint {
            lines.append(String(
                format: "click point=(%.1f,%.1f) global top-left origin (AX space, not flipped), kCGHIDEventTap",
                Double(point.x),
                Double(point.y)
            ))
        } else {
            lines.append("click point=none (no click posted for the last target)")
        }
        lines.append(ax.focusSummary())
        lines.append(saveFailureShots(name, ax))
        for line in lines {
            print("UI_DIAG \(name) " + redact(line.replacingOccurrences(of: "\n", with: " ")))
        }
    }

    /// `build/ui-fail` under the repository root. CI zips it onto the PR comment when not empty.
    private func failDirectory() -> String {
        (fixtureRoot as NSString).appendingPathComponent("build/ui-fail")
    }

    private func resetFailDirectory() {
        let dir = failDirectory()
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// `screencapture -x -o -l <window id>` for up to three on-screen app windows, front first.
    private func saveFailureShots(_ name: String, _ ax: AXClient) -> String {
        let ids = ax.onScreenWindowIDs()
        guard !ids.isEmpty else { return "screenshot none: no on-screen app window" }
        let dir = failDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var saved: [String] = []
        for (index, id) in ids.prefix(3).enumerated() {
            let file = index == 0 ? "\(name).png" : "\(name)-w\(index + 1).png"
            let path = (dir as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(id), path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                continue
            }
            task.waitUntilExit()
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
            if task.terminationStatus == 0, (size?.intValue ?? 0) > 0 {
                saved.append("build/ui-fail/\(file) (window \(id))")
            }
        }
        if saved.isEmpty {
            return "screenshot failed for windows \(ids.map { String($0) }.joined(separator: ",")) (Screen Recording permission?)"
        }
        return "screenshot " + saved.joined(separator: " ")
    }

    /// Activate, raise the key window, and verify the app is frontmost. A failure is recorded
    /// on the next check as "not frontmost".
    private func activate() {
        guard process != nil else { return }
        client?.ensureFrontmost()
    }

    /// Re-activate and wait until the app is frontmost and a window is key.
    /// A success drops frontmost failures from the wait so the next check is not failed by them.
    @discardableResult
    private func waitForKeyWindow(_ ax: AXClient, seconds: Double = 6) -> Bool {
        let ready = waitUntil(seconds) {
            _ = ax.takeFrontmostIssue()
            guard ax.ensureFrontmost() == nil else { return false }
            return !ax.focusedWindowTitle().isEmpty
        }
        if ready {
            _ = ax.takeFrontmostIssue()
        }
        return ready
    }

    private func stopApp() {
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        if !dataDir.isEmpty {
            try? FileManager.default.removeItem(atPath: dataDir)
            dataDir = ""
        }
        if !downloadsDir.isEmpty {
            try? FileManager.default.removeItem(atPath: downloadsDir)
            downloadsDir = ""
        }
    }

    private func downloadFileNames() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: downloadsDir)) ?? []
        return Set(contents.filter { $0 != ".DS_Store" })
    }

    private func leftoverPartials() -> [String] {
        downloadFileNames().filter { $0.hasSuffix(".download") }.sorted()
    }

    private func hasQuarantine(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) > 0
    }

    private func waitUntil(_ seconds: Double, _ body: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if body() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return body()
    }

    private func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

private func launchctlPath() -> String {
    if FileManager.default.isExecutableFile(atPath: "/bin/launchctl") {
        return "/bin/launchctl"
    }
    return "/usr/bin/launchctl"
}

private func commandOutput(_ path: String, _ args: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
    } catch {
        return ""
    }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func actRunnerPath() -> String {
    // Walk to launchd. The last ancestor below launchd is the process macOS treats as responsible
    // for Accessibility (TCC), so print the whole chain and name that one explicitly.
    var pid = ProcessInfo.processInfo.processIdentifier
    var chain: [String] = []
    var runner: String?
    var top = ""
    for _ in 0..<40 {
        let line = commandOutput("/bin/ps", ["-p", String(pid), "-o", "ppid="]).trimmingCharacters(in: .whitespaces)
        guard let parent = Int32(line) else { break }
        let command = commandOutput("/bin/ps", ["-p", String(pid), "-o", "comm="]).trimmingCharacters(in: .whitespacesAndNewlines)
        let path = redact(command)
        chain.append(path)
        top = path
        let name = ((command as NSString).lastPathComponent).lowercased()
        if runner == nil, name.contains("act_runner") || name.contains("act-runner") || name.contains("gitea-runner") {
            runner = path
        }
        if parent <= 1 || parent == pid { break }
        pid = parent
    }
    let responsible = runner ?? top
    return "Process chain (child to parent): " + chain.joined(separator: " <- ")
        + "\nAdd this binary in Accessibility: " + responsible
}

private func redact(_ text: String) -> String {
    let home = NSHomeDirectory()
    guard home.count > 1 else { return text }
    return text.replacingOccurrences(of: home, with: "<home>")
}

let status = UITestSession().run()
exit(status)
