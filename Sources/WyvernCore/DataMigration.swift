// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One-time copy of bookmarks, media permissions, the icon cache, and UserDefaults
/// from the Wyvern data locations into the current product locations.
public enum DataMigration {
    public enum FileResult: Equatable {
        case skippedOverride
        case skippedDestinationExists
        case skippedNoLegacy
        case migrated(from: String)
        case copyFailed
    }

    public static func preferredLegacyDirectory(among candidates: [URL], fileManager: FileManager) -> URL? {
        candidates.first { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Copy `source` onto `destination` (destination must not exist). Remove `source` only after a verified copy.
    public static func migrateFiles(
        legacyCandidates: [URL],
        destination: URL,
        fileManager: FileManager,
        skip: Bool
    ) -> FileResult {
        if skip {
            return .skippedOverride
        }
        var destIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &destIsDirectory) {
            return .skippedDestinationExists
        }
        guard let source = preferredLegacyDirectory(among: legacyCandidates, fileManager: fileManager) else {
            return .skippedNoLegacy
        }
        do {
            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            guard verifyCopy(from: source, to: destination, fileManager: fileManager) else {
                try? fileManager.removeItem(at: destination)
                return .copyFailed
            }
            try fileManager.removeItem(at: source)
            return .migrated(from: source.lastPathComponent)
        } catch {
            try? fileManager.removeItem(at: destination)
            return .copyFailed
        }
    }

    /// Copy settings and other keys from the old defaults domain once. Sets `AppInfo.defaultsMigrationMarkerKey`.
    @discardableResult
    public static func migrateDefaults(
        legacy: UserDefaults,
        current: UserDefaults,
        legacyDomainName: String,
        legacySettingsKey: String,
        currentSettingsKey: String,
        markerKey: String = AppInfo.defaultsMigrationMarkerKey
    ) -> Bool {
        if current.bool(forKey: markerKey) {
            return false
        }
        if current.object(forKey: currentSettingsKey) == nil {
            let payload = current.data(forKey: legacySettingsKey) ?? legacy.data(forKey: legacySettingsKey)
            if let payload {
                current.set(payload, forKey: currentSettingsKey)
            }
        }
        if let domain = legacy.persistentDomain(forName: legacyDomainName) {
            for (key, value) in domain {
                if key == markerKey || key == legacySettingsKey || key == currentSettingsKey {
                    continue
                }
                if current.object(forKey: key) == nil {
                    current.set(value, forKey: key)
                }
            }
        }
        current.set(true, forKey: markerKey)
        return true
    }

    private static func verifyCopy(from source: URL, to destination: URL, fileManager: FileManager) -> Bool {
        let sourceMap = fileMap(root: source, fileManager: fileManager)
        let destMap = fileMap(root: destination, fileManager: fileManager)
        guard sourceMap.count == destMap.count else { return false }
        for (path, size) in sourceMap {
            guard destMap[path] == size else { return false }
        }
        return true
    }

    private static func fileMap(root: URL, fileManager: FileManager) -> [String: Int] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var map: [String: Int] = [:]
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }
            guard values?.isRegularFile == true else { continue }
            var relative = url.standardizedFileURL.path
            if relative.hasPrefix(rootPath) {
                relative = String(relative.dropFirst(rootPath.count))
                if relative.hasPrefix("/") {
                    relative.removeFirst()
                }
            }
            map[relative] = values?.fileSize ?? 0
        }
        return map
    }
}
