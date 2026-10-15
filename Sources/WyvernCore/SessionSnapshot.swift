// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One tab in a saved window. Web tabs store a URL (nil is the new-tab page).
/// Terminal tabs store the bookmark id they were opened from.
public struct SessionTabSnapshot: Codable, Equatable, Sendable {
    public var kind: TabKind
    public var url: String?
    public var terminalBookmarkID: UUID?
    /// Index of the source tab in the same window snapshot. Absent on older snapshots.
    /// A DevTools record whose source was not restored is skipped.
    public var devtoolsSourceIndex: Int?

    public init(
        kind: TabKind,
        url: String? = nil,
        terminalBookmarkID: UUID? = nil,
        devtoolsSourceIndex: Int? = nil
    ) {
        self.kind = kind
        self.url = url
        self.terminalBookmarkID = terminalBookmarkID
        self.devtoolsSourceIndex = devtoolsSourceIndex
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
        case terminalBookmarkID
        case devtoolsSourceIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(TabKind.self, forKey: .kind)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? nil
        terminalBookmarkID = try container.decodeIfPresent(UUID.self, forKey: .terminalBookmarkID)
        devtoolsSourceIndex = try container.decodeIfPresent(Int.self, forKey: .devtoolsSourceIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(terminalBookmarkID, forKey: .terminalBookmarkID)
        try container.encodeIfPresent(devtoolsSourceIndex, forKey: .devtoolsSourceIndex)
    }
}

/// Ordered tabs in one window, plus the selected index in that order.
/// `tile` is absent on snapshots written before split view. A bad `tile` value is ignored
/// so the tabs still restore.
public struct SessionWindowSnapshot: Codable, Equatable, Sendable {
    public var tabs: [SessionTabSnapshot]
    public var selectedIndex: Int
    public var tile: SessionTileSnapshot?

    public init(tabs: [SessionTabSnapshot], selectedIndex: Int, tile: SessionTileSnapshot? = nil) {
        self.tabs = tabs
        self.selectedIndex = Self.clamped(selectedIndex, count: tabs.count)
        self.tile = tile
    }

    public static func clamped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    private enum CodingKeys: String, CodingKey {
        case tabs
        case selectedIndex
        case tile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tabs = try container.decodeIfPresent([SessionTabSnapshot].self, forKey: .tabs) ?? []
        let selected = try container.decodeIfPresent(Int.self, forKey: .selectedIndex) ?? 0
        // `try?` so a corrupt tile does not throw away the rest of the window.
        let tile = try? container.decodeIfPresent(SessionTileSnapshot.self, forKey: .tile)
        self.init(tabs: tabs, selectedIndex: selected, tile: tile ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(selectedIndex, forKey: .selectedIndex)
        try container.encodeIfPresent(tile, forKey: .tile)
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
/// How a saved web tab is loaded again. A tampered snapshot must not mark an arbitrary
/// `file:` URL as typed (that bypasses the file-navigation check) and must not restore
/// `javascript:` or `data:` URLs. Local HTML is still restored, the same extensions an
/// external open accepts for a document.
public enum SessionRestoredWebLoad: Equatable, Sendable {
    case web(URL)
    case localDocument(URL)
    case newTab
}

public enum SessionRestorePolicy {
    public static let maxSnapshotBytes = 32 * 1024 * 1024
    public static let localDocumentExtensions: Set<String> = ["html", "htm", "xhtml"]

    public static func webLoad(for raw: String?) -> SessionRestoredWebLoad {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .newTab
        }
        switch scheme {
        case "http", "https", "about", "wyvern":
            return .web(url)
        case "file":
            if localDocumentExtensions.contains(url.pathExtension.lowercased()) {
                return .localDocument(url)
            }
            return .newTab
        default:
            return .newTab
        }
    }

    public static func decodeSnapshot(_ data: Data, maxBytes: Int = maxSnapshotBytes) -> SessionSnapshot? {
        guard data.count <= maxBytes else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}

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
            try PrivateFile.ensureDirectory(directory)
            let text = clean ? "true\n" : "false\n"
            try PrivateFile.write(Data(text.utf8), to: url)
            return true
        } catch {
            return false
        }
    }

    public static func loadSnapshot(at url: URL, maxBytes: Int = SessionRestorePolicy.maxSnapshotBytes) -> SessionSnapshot? {
        if let size = fileByteCount(url), size > maxBytes {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SessionRestorePolicy.decodeSnapshot(data, maxBytes: maxBytes)
    }

    private static func fileByteCount(_ url: URL) -> Int? {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
            return size
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let number = attributes?[.size] as? NSNumber {
            return number.intValue
        }
        return nil
    }

    @discardableResult
    public static func saveSnapshot(_ snapshot: SessionSnapshot, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return false }
        do {
            try PrivateFile.write(data, to: url)
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
