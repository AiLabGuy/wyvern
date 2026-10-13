// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One tab in a saved window. Web tabs store a URL (nil is the new-tab page).
/// Terminal tabs store the bookmark id they were opened from.
public struct SessionTabSnapshot: Codable, Equatable, Sendable {
    public var kind: TabKind
    public var url: String?
    public var terminalBookmarkID: UUID?

    public init(kind: TabKind, url: String? = nil, terminalBookmarkID: UUID? = nil) {
        self.kind = kind
        self.url = url
        self.terminalBookmarkID = terminalBookmarkID
    }
}

/// Ordered tabs in one window, plus the selected index in that order.
public struct SessionWindowSnapshot: Codable, Equatable, Sendable {
    public var tabs: [SessionTabSnapshot]
    public var selectedIndex: Int

    public init(tabs: [SessionTabSnapshot], selectedIndex: Int) {
        self.tabs = tabs
        self.selectedIndex = Self.clamped(selectedIndex, count: tabs.count)
    }

    public static func clamped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    private enum CodingKeys: String, CodingKey {
        case tabs
        case selectedIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tabs = try container.decodeIfPresent([SessionTabSnapshot].self, forKey: .tabs) ?? []
        let selected = try container.decodeIfPresent(Int.self, forKey: .selectedIndex) ?? 0
        self.init(tabs: tabs, selectedIndex: selected)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(selectedIndex, forKey: .selectedIndex)
    }
}

/// Windows captured from one run, in front-to-back order as the app last saved them.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var windows: [SessionWindowSnapshot]

    public init(windows: [SessionWindowSnapshot]) {
        self.windows = windows
    }

    public var hasRestorableTabs: Bool {
        windows.contains { !$0.tabs.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case windows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decodeIfPresent([SessionWindowSnapshot].self, forKey: .windows) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows, forKey: .windows)
    }
}

/// What the next launch should do with the previous run's snapshot.
public enum SessionStartupChoice: Equatable, Sendable {
    /// The last run did not exit cleanly and a snapshot with tabs exists.
    case offerCrashRestore
    case restoreLastSession
    case newTab
    case customURL(String)
}

public enum SessionStartup {
    /// Crash restore wins over the startup setting. An empty custom URL opens a new tab.
    public static func choice(
        offerCrashRestore: Bool,
        startupPage: StartupPage,
        startupURL: String
    ) -> SessionStartupChoice {
        if offerCrashRestore {
            return .offerCrashRestore
        }
        switch startupPage {
        case .newTab:
            return .newTab
        case .restoreLastSession:
            return .restoreLastSession
        case .customURL:
            let trimmed = startupURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .newTab
            }
            return .customURL(trimmed)
        }
    }
}

/// JSON snapshot plus a clean-exit flag under Application Support (`AppLocations.dataDirectory`).
public struct SessionArchive {
    public static let liveFileName = "session-snapshot.json"
    public static let previousFileName = "session-previous.json"
    public static let cleanExitFileName = "session-clean-exit"

    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var liveURL: URL {
        directory.appendingPathComponent(Self.liveFileName)
    }

    public var previousURL: URL {
        directory.appendingPathComponent(Self.previousFileName)
    }

    public var cleanExitURL: URL {
        directory.appendingPathComponent(Self.cleanExitFileName)
    }

    /// Missing flag means this feature has never launched here, which counts as a clean exit.
    public func readCleanExit() -> Bool {
        Self.readCleanExit(at: cleanExitURL)
    }

    @discardableResult
    public func writeCleanExit(_ clean: Bool) -> Bool {
        Self.writeCleanExit(clean, to: cleanExitURL, directory: directory)
    }

    public func loadLive() -> SessionSnapshot? {
        Self.loadSnapshot(at: liveURL)
    }

    public func loadPrevious() -> SessionSnapshot? {
        Self.loadSnapshot(at: previousURL)
    }

    @discardableResult
    public func saveLive(_ snapshot: SessionSnapshot) -> Bool {
        Self.saveSnapshot(snapshot, to: liveURL)
    }

    /// Copies the live snapshot aside as the previous run, then marks this run unclean.
    /// Crash restore is offered only when the previous run was unclean and saved at least one tab.
    public func beginRun() -> SessionLaunchState {
        let clean = readCleanExit()
        let live = loadLive()
        if let live {
            _ = Self.saveSnapshot(live, to: previousURL)
        } else {
            try? FileManager.default.removeItem(at: previousURL)
        }
        _ = writeCleanExit(false)
        let offer = !clean && live?.hasRestorableTabs == true
        return SessionLaunchState(wasCleanExit: clean, previous: live, offerCrashRestore: offer)
    }

    public func markCleanExit() {
        _ = writeCleanExit(true)
    }

    public static func readCleanExit(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !text.isEmpty else {
            return true
        }
        if text == "false" || text == "0" {
            return false
        }
        if text == "true" || text == "1" {
            return true
        }
        return true
    }

    @discardableResult
    public static func writeCleanExit(_ clean: Bool, to url: URL, directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let text = clean ? "true\n" : "false\n"
            try Data(text.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func loadSnapshot(at url: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    @discardableResult
    public static func saveSnapshot(_ snapshot: SessionSnapshot, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

public struct SessionLaunchState: Equatable, Sendable {
    public var wasCleanExit: Bool
    public var previous: SessionSnapshot?
    public var offerCrashRestore: Bool

    public init(wasCleanExit: Bool, previous: SessionSnapshot?, offerCrashRestore: Bool) {
        self.wasCleanExit = wasCleanExit
        self.previous = previous
        self.offerCrashRestore = offerCrashRestore
    }
}
