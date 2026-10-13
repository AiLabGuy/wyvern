// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public extension Notification.Name {
    static let wyvernSitePermissionsDidChange = Notification.Name("\(AppInfo.bundleIdentifier).sitePermissionsDidChange")
}

/// Per-site choices beyond the camera and microphone prompt store.
/// Camera and microphone stay in `MediaPermissionStore` so Ask still prompts.
public enum SitePermissionKind: String, Codable, CaseIterable, Sendable {
    case camera
    case microphone
    case location
    case notifications
    case popups
    case autoplay
}

/// Ask leaves the existing behavior in place. Allow and Block are explicit.
public enum SitePermissionChoice: String, Codable, Equatable, Sendable {
    case ask
    case allow
    case block
}

/// How a new web view should treat autoplay. Ask does not write the WebKit property.
public enum SitePlaybackOverride: Equatable, Sendable {
    case leaveDefault
    case requireUserAction
    case allowWithoutUserAction
}

public enum SitePermissionPolicy {
    /// Location and notifications: WKWebView has no public permission prompt.
    /// The choice is stored. Nothing in this process can grant the page access,
    /// so those requests stay denied whether the saved choice is Ask, Allow, or Block.
    public static func canApplyInWebKit(_ kind: SitePermissionKind) -> Bool {
        switch kind {
        case .location, .notifications:
            return false
        case .camera, .microphone, .popups, .autoplay:
            return true
        }
    }

    /// Absent location and notification choices display as Block (denied).
    /// They are not written until the user picks a value. Other kinds display Ask.
    public static func displayedChoice(stored: SitePermissionChoice?, kind: SitePermissionKind) -> SitePermissionChoice {
        if let stored {
            return stored
        }
        switch kind {
        case .location, .notifications:
            return .block
        case .camera, .microphone, .popups, .autoplay:
            return .ask
        }
    }

    public static func title(_ choice: SitePermissionChoice) -> String {
        switch choice {
        case .ask: return "Ask"
        case .allow: return "Allow"
        case .block: return "Block"
        }
    }

    /// Ask and Allow keep today's popup behavior (the new view is created).
    /// Block is the only choice that refuses `createWebViewWith`.
    public static func allowsPopup(_ choice: SitePermissionChoice) -> Bool {
        choice != .block
    }

    public static func playbackOverride(_ choice: SitePermissionChoice) -> SitePlaybackOverride {
        switch choice {
        case .ask:
            return .leaveDefault
        case .allow:
            return .allowWithoutUserAction
        case .block:
            return .requireUserAction
        }
    }

    /// Nil means Ask: revoke the stored camera or microphone decision and prompt.
    public static func mediaDecision(for choice: SitePermissionChoice) -> MediaStoredDecision? {
        switch choice {
        case .ask:
            return nil
        case .allow:
            return .alwaysAllow
        case .block:
            return .alwaysDeny
        }
    }

    public static func choice(for decision: MediaStoredDecision?) -> SitePermissionChoice? {
        switch decision {
        case .alwaysAllow:
            return .allow
        case .alwaysDeny:
            return .block
        case nil:
            return nil
        }
    }

    /// `scheme://host` or `scheme://host:port`. Nil when the URL has no host.
    public static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme, !scheme.isEmpty,
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return MediaPermissionPolicy.originKey(scheme: scheme, host: host, port: url.port ?? 0)
    }

    public static func listedOrigins(mediaOrigins: [String], siteOrigins: [String]) -> [String] {
        Array(Set(mediaOrigins).union(siteOrigins)).sorted()
    }
}

/// JSON file of per-site choices other than the camera and microphone prompt store.
/// Callers use the store from one thread. The app uses it on the main thread.
public final class SitePermissionStore {
    public let fileURL: URL
    private var sites: [String: [SitePermissionKind: SitePermissionChoice]] = [:]
    private var order: [String] = []

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(AppInfo.sitePermissionsFileName)
        load()
    }

    public convenience init() {
        self.init(directory: AppLocations.dataDirectory)
    }

    public var origins: [String] {
        order
    }

    /// Nil when the user has not stored a choice. That is Ask for enforcement,
    /// except location and notifications, which stay denied because they cannot be prompted.
    public func storedChoice(origin: String, kind: SitePermissionKind) -> SitePermissionChoice? {
        sites[origin]?[kind]
    }

    public func choice(origin: String, kind: SitePermissionKind) -> SitePermissionChoice {
        storedChoice(origin: origin, kind: kind) ?? .ask
    }

    public func set(_ choice: SitePermissionChoice, origin: String, kind: SitePermissionKind) {
        let origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origin.isEmpty else { return }
        let keepAsk = kind == .location || kind == .notifications
        if choice == .ask && !keepAsk {
            guard sites[origin]?[kind] != nil else { return }
            sites[origin]?.removeValue(forKey: kind)
            if sites[origin]?.isEmpty != false {
                sites.removeValue(forKey: origin)
                order.removeAll { $0 == origin }
            }
        } else {
            if sites[origin] == nil {
                sites[origin] = [:]
                order.append(origin)
            }
            guard sites[origin]?[kind] != choice else { return }
            sites[origin]?[kind] = choice
        }
        persist()
        postChange()
    }

    public func remove(origin: String) {
        guard sites.removeValue(forKey: origin) != nil else { return }
        order.removeAll { $0 == origin }
        persist()
        postChange()
    }

    public func removeAll() {
        guard !sites.isEmpty else {
            persist()
            return
        }
        sites.removeAll()
        order.removeAll()
        persist()
        postChange()
    }

    private func load() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            sites = [:]
            order = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let file = try decoder.decode(SitePermissionFile.self, from: data)
            var loaded: [String: [SitePermissionKind: SitePermissionChoice]] = [:]
            var loadedOrder: [String] = []
            for record in file.sites {
                let origin = record.origin.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !origin.isEmpty else { continue }
                var choices: [SitePermissionKind: SitePermissionChoice] = [:]
                for (key, value) in record.choices {
                    guard let kind = SitePermissionKind(rawValue: key),
                          let choice = SitePermissionChoice(rawValue: value) else {
                        continue
                    }
                    if choice == .ask && kind != .location && kind != .notifications {
                        continue
                    }
                    choices[kind] = choice
                }
                guard !choices.isEmpty else { continue }
                if loaded[origin] == nil {
                    loadedOrder.append(origin)
                }
                loaded[origin] = choices
            }
            sites = loaded
            order = loadedOrder
        } catch {
            sites = [:]
            order = []
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
            let records = order.compactMap { origin -> SitePermissionRecord? in
                guard let choices = sites[origin], !choices.isEmpty else { return nil }
                var raw: [String: String] = [:]
                for (kind, choice) in choices {
                    raw[kind.rawValue] = choice.rawValue
                }
                return SitePermissionRecord(origin: origin, choices: raw)
            }
            let file = SitePermissionFile(version: 1, sites: records)
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            return
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: .wyvernSitePermissionsDidChange, object: self)
    }
}

private struct SitePermissionFile: Codable {
    var version: Int
    var sites: [SitePermissionRecord]
}

private struct SitePermissionRecord: Codable {
    var origin: String
    var choices: [String: String]
}
