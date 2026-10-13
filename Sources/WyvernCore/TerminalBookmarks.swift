// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// SHA-256 of the exact command string the user confirmed. A changed command no longer matches.
public enum TerminalCommandHash {
    public static func hex(_ command: String) -> String {
        let digest = SHA256.hash(data: Data(command.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// How a stored command is handed to the user's login shell.
/// The command is one argv element. Nothing else is interpolated into it.
public enum TerminalLaunch {
    public static func arguments(shell: String, command: String) -> [String] {
        [shell, "-lc", command]
    }

    /// Login shell from the passwd entry. Falls back to `/bin/zsh` when that entry is empty.
    public static func loginShellPath() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasPrefix("/"), !path.contains("\n") {
                return path
            }
        }
        return "/bin/zsh"
    }

    /// Bookmark shell, then the settings shell, then the login shell. Relative paths are rejected.
    public static func resolvedShell(bookmarkShell: String, defaultShell: String) -> String {
        for candidate in [bookmarkShell, defaultShell] {
            if candidate.contains("\n") || candidate.contains("\r") || candidate.contains("\0") {
                continue
            }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/"), !trimmed.contains("\n"), !trimmed.contains("\0") {
                return trimmed
            }
        }
        return loginShellPath()
    }

    /// Absolute directory for `startProcess`. Empty, `~`, and relative paths stay nil so the shell starts at home.
    public static func expandedDirectory(_ raw: String) -> String? {
        if raw.contains("\n") || raw.contains("\r") || raw.contains("\0") {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" || trimmed == "~/" {
            return nil
        }
        if trimmed.contains("\n") || trimmed.contains("\0") {
            return nil
        }
        if trimmed.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + String(trimmed.dropFirst(1))
        }
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        return nil
    }

    /// Address-field caption: shell name and working directory. This is not the command.
    public static func fieldCaption(shell: String, directory: String) -> String {
        let name = URL(fileURLWithPath: shell).lastPathComponent
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.isEmpty ? "~" : trimmed
        return "\(name)  \(shown)"
    }
}

public struct TerminalBookmark: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    /// Imported bookmarks stay false until the user reviews them in Settings.
    public var enabled: Bool
    /// Hex hash of the command the user agreed to run. Nil until that confirmation.
    public var confirmedCommandHash: String?
    /// Optional working directory. Empty starts the shell in the home directory.
    public var workingDirectory: String
    /// Optional absolute shell path. Empty uses the settings default, then the login shell.
    public var shell: String
    /// When false, opening this bookmark replaces the active terminal tab.
    public var openInNewTab: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        enabled: Bool,
        confirmedCommandHash: String? = nil,
        workingDirectory: String = "",
        shell: String = "",
        openInNewTab: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.enabled = enabled
        self.confirmedCommandHash = confirmedCommandHash
        self.workingDirectory = workingDirectory
        self.shell = shell
        self.openInNewTab = openInNewTab
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case enabled
        case confirmedCommandHash
        case workingDirectory
        case shell
        case openInNewTab
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        confirmedCommandHash = try container.decodeIfPresent(String.self, forKey: .confirmedCommandHash)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        shell = try container.decodeIfPresent(String.self, forKey: .shell) ?? ""
        openInNewTab = try container.decodeIfPresent(Bool.self, forKey: .openInNewTab) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(confirmedCommandHash, forKey: .confirmedCommandHash)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(shell, forKey: .shell)
        try container.encode(openInNewTab, forKey: .openInNewTab)
    }

    public var needsConfirmation: Bool {
        confirmedCommandHash != TerminalCommandHash.hex(command)
    }

    /// True only after the user has enabled the bookmark and confirmed this exact command.
    public var canLaunch: Bool {
        enabled && !needsConfirmation
    }
}

public extension Notification.Name {
    static let wyvernTerminalBookmarksDidChange = Notification.Name("\(AppInfo.bundleIdentifier).terminalBookmarksDidChange")
}

/// JSON file of terminal bookmarks. The file mode is `0600`. Import never enables or confirms a command.
public final class TerminalBookmarkStore {
    public static let sharingWarning =
        "These commands run with your user privileges. Sharing or exporting this file shares those commands."

    public let fileURL: URL
    public private(set) var bookmarks: [TerminalBookmark] = []
    public private(set) var lastErrorDescription: String?

    public init(directory: URL, fileName: String = AppInfo.terminalBookmarksFileName) {
        fileURL = directory.appendingPathComponent(fileName)
        load()
    }

    public var enabledBookmarks: [TerminalBookmark] {
        bookmarks.filter(\.enabled)
    }

    @discardableResult
    public func add(
        name: String,
        command: String,
        workingDirectory: String = "",
        shell: String = "",
        openInNewTab: Bool = true
    ) -> TerminalBookmark? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !command.isEmpty else { return nil }
        let item = TerminalBookmark(
            name: trimmedName,
            command: command,
            enabled: true,
            confirmedCommandHash: nil,
            workingDirectory: workingDirectory,
            shell: shell,
            openInNewTab: openInNewTab
        )
        bookmarks.append(item)
        persist()
        postChange()
        return item
    }

    public func update(
        id: UUID,
        name: String,
        command: String,
        workingDirectory: String? = nil,
        shell: String? = nil,
        openInNewTab: Bool? = nil
    ) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !command.isEmpty else { return }
        let nextDirectory = workingDirectory ?? bookmarks[index].workingDirectory
        let nextShell = shell ?? bookmarks[index].shell
        let nextTab = openInNewTab ?? bookmarks[index].openInNewTab
        let launchChanged = bookmarks[index].command != command
            || bookmarks[index].workingDirectory != nextDirectory
            || bookmarks[index].shell != nextShell
        bookmarks[index].name = trimmedName
        bookmarks[index].command = command
        bookmarks[index].workingDirectory = nextDirectory
        bookmarks[index].shell = nextShell
        bookmarks[index].openInNewTab = nextTab
        if launchChanged {
            bookmarks[index].confirmedCommandHash = nil
        }
        persist()
        postChange()
    }

    public func remove(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist()
        postChange()
    }

    /// Records that the user confirmed the command currently stored for this bookmark.
    public func confirm(id: UUID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].confirmedCommandHash = TerminalCommandHash.hex(bookmarks[index].command)
        persist()
        postChange()
    }

    /// Reviewing an import enables the bookmark. It does not run the command.
    public func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].enabled = enabled
        persist()
        postChange()
    }

    public func bookmark(id: UUID) -> TerminalBookmark? {
        bookmarks.first { $0.id == id }
    }

    /// Imported commands arrive disabled and unconfirmed. This method does not start a process.
    public func importBookmarks(_ items: [TerminalBookmark]) {
        for item in items {
            var stored = item
            stored.enabled = false
            stored.confirmedCommandHash = nil
            bookmarks.append(stored)
        }
        persist()
        postChange()
    }

    private func load() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            bookmarks = []
            return
        }
        tightenFile()
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let file = try decoder.decode(StoredFile.self, from: data)
            bookmarks = file.bookmarks
        } catch {
            bookmarks = []
            lastErrorDescription = error.localizedDescription
            quarantineCorrupt()
        }
    }

    private func persist() {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(StoredFile(version: 1, bookmarks: bookmarks))
            try Self.writePrivate(data, to: fileURL)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func tightenFile() {
        _ = fileURL.path.withCString { chmod($0, 0o600) }
    }

    private func quarantineCorrupt() {
        let corruptURL = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: corruptURL)
        try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
    }

    private func postChange() {
        NotificationCenter.default.post(name: .wyvernTerminalBookmarksDidChange, object: self)
    }

    /// `open(O_CREAT|O_EXCL)` is not used: a rewrite replaces the previous file.
    /// `fchmod` forces `0600` so the process umask cannot leave the file group-readable.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        if FileManager.default.fileExists(atPath: temporary.path) {
            try FileManager.default.removeItem(at: temporary)
        }
        let fd = temporary.path.withCString { open($0, O_CREAT | O_TRUNC | O_WRONLY, mode_t(0o600)) }
        guard fd >= 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { _ = close(fd) }
        if fchmod(fd, mode_t(0o600)) != 0 {
            throw CocoaError(.fileWriteNoPermission)
        }
        var remaining = data
        while !remaining.isEmpty {
            let wrote = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base, buffer.count)
            }
            if wrote < 0 {
                throw CocoaError(.fileWriteUnknown)
            }
            if wrote == 0 {
                throw CocoaError(.fileWriteUnknown)
            }
            remaining.removeFirst(wrote)
        }
        if fsync(fd) != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
        let renamed = temporary.path.withCString { source in
            url.path.withCString { destination in
                rename(source, destination)
            }
        }
        if renamed != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
        if url.path.withCString({ chmod($0, 0o600) }) != 0 {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private struct StoredFile: Codable {
        var version: Int
        var bookmarks: [TerminalBookmark]
    }
}
