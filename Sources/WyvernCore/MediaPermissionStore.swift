// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public extension Notification.Name {
    static let wyvernMediaPermissionsDidChange = Notification.Name("\(AppInfo.bundleIdentifier).mediaPermissionsDidChange")
}

public struct MediaPermissionEntry: Codable, Equatable, Sendable {
    public var origin: String
    public var kind: MediaCaptureKind
    public var decision: MediaStoredDecision

    public init(origin: String, kind: MediaCaptureKind, decision: MediaStoredDecision) {
        self.origin = origin
        self.kind = kind
        self.decision = decision
    }
}

private struct MediaPermissionFile: Codable {
    var version: Int
    var entries: [MediaPermissionEntry]
}

/// JSON file of lasting microphone and camera choices, keyed by origin and kind.
/// Callers use the store from one thread. The app uses it on the main thread.
public final class MediaPermissionStore {
    public private(set) var entries: [MediaPermissionEntry] = []
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(AppInfo.mediaPermissionsFileName)
        load()
    }

    public convenience init() {
        self.init(directory: AppLocations.dataDirectory)
    }

    public func decision(origin: String, kind: MediaCaptureKind) -> MediaStoredDecision? {
        entries.first { $0.origin == origin && $0.kind == kind }?.decision
    }

    public func set(_ decision: MediaStoredDecision, origin: String, kind: MediaCaptureKind) {
        if let index = entries.firstIndex(where: { $0.origin == origin && $0.kind == kind }) {
            entries[index].decision = decision
        } else {
            entries.append(MediaPermissionEntry(origin: origin, kind: kind, decision: decision))
        }
        persist()
        postChange()
    }

    public func revoke(origin: String, kind: MediaCaptureKind) {
        let before = entries.count
        entries.removeAll { $0.origin == origin && $0.kind == kind }
        guard entries.count != before else { return }
        persist()
        postChange()
    }

    public func removeAll() {
        guard !entries.isEmpty else {
            persist()
            return
        }
        entries.removeAll()
        persist()
        postChange()
    }

    private func load() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let file = try decoder.decode(MediaPermissionFile.self, from: data)
            entries = file.entries
        } catch {
            entries = []
            quarantineCorruptFile(manager: manager)
        }
    }

    private func quarantineCorruptFile(manager: FileManager) {
        let corruptURL = fileURL.appendingPathExtension("corrupt")
        if manager.fileExists(atPath: corruptURL.path) {
            try? manager.removeItem(at: corruptURL)
        }
        do {
            try manager.moveItem(at: fileURL, to: corruptURL)
        } catch {
            try? manager.removeItem(at: fileURL)
        }
    }

    private func persist() {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = MediaPermissionFile(version: 1, entries: entries)
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            return
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: .wyvernMediaPermissionsDidChange, object: self)
    }
}
