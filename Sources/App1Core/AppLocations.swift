// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where bookmarks, settings, media permissions, the icon cache, and downloads live.
/// A launch flag can point this at another directory. The defaults suite name is a hash, not the path.
public enum AppLocations {
    private static var overrideDirectory: URL?
    private static var overrideDownloads: URL?

    public static var dataDirectory: URL {
        overrideDirectory ?? AppInfo.applicationSupportDirectory
    }

    /// `~/Downloads`, or `--app1-downloads-dir` when that flag is set.
    public static var downloadsDirectory: URL {
        if let overrideDownloads {
            return overrideDownloads
        }
        if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return folder
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    public static var defaultsSuiteName: String? {
        guard let overrideDirectory else { return nil }
        return suiteName(for: overrideDirectory)
    }

    public static var userDefaults: UserDefaults {
        if let defaultsSuiteName, let suite = UserDefaults(suiteName: defaultsSuiteName) {
            return suite
        }
        return .standard
    }

    public static func apply(_ configuration: LaunchConfiguration) {
        if let path = configuration.dataDirectory, !path.isEmpty {
            overrideDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            overrideDirectory = nil
        }
        if let path = configuration.downloadsDirectory, !path.isEmpty {
            overrideDownloads = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            overrideDownloads = nil
        }
    }

    public static func setDataDirectory(_ url: URL?) {
        overrideDirectory = url
    }

    public static func setDownloadsDirectory(_ url: URL?) {
        overrideDownloads = url
    }

    public static var isDataDirectoryOverridden: Bool {
        overrideDirectory != nil
    }

    /// True when `--app1-downloads-dir` is set. That folder wins over the settings path for this launch.
    public static var isDownloadsDirectoryOverridden: Bool {
        overrideDownloads != nil
    }

    /// Copy App1 bookmarks, media permissions, the icon cache, and UserDefaults into the
    /// current product locations. `--app1-data-dir` skips this.
    public static func migratePersistentStateIfNeeded() {
        guard overrideDirectory == nil else { return }
        let support = AppInfo.applicationSupportRoot()
        _ = DataMigration.migrateFiles(
            legacyCandidates: AppInfo.legacyDataDirectories(applicationSupport: support),
            destination: AppInfo.applicationSupportDirectory,
            fileManager: .default,
            skip: false
        )
        guard let legacy = UserDefaults(suiteName: AppInfo.legacyBundleIdentifier) else { return }
        _ = DataMigration.migrateDefaults(
            legacy: legacy,
            current: userDefaults,
            legacyDomainName: AppInfo.legacyBundleIdentifier,
            legacySettingsKey: AppInfo.legacySettingsDefaultsKey,
            currentSettingsKey: AppInfo.settingsDefaultsKey
        )
    }

    public static func suiteName(for directory: URL) -> String {
        let path = directory.standardizedFileURL.path
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return "\(AppInfo.bundleIdentifier).data.\(String(hash, radix: 16))"
    }
}
