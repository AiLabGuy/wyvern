// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Product identity used by the app target, the core library, and tests.
/// `displayName` and `shortName` are the user-facing name (`DISPLAY_NAME` in
/// `config/product.env`). `productName` is the legal name (`PRODUCT_NAME`).
/// The shipped bundle id and version in Info.plist come from that file at
/// build time; `bundleIdentifier` is read from the running bundle and falls
/// back to that same id.
public enum AppInfo {
    public static let displayName = "Wyvern"
    public static let shortName = "Wyvern"
    public static let productName = "Wyvern Browser"
    public static let fallbackBundleIdentifier = "com.example.wyvern"
    public static let legacyBundleIdentifier = "com.example.wyvern.legacy"
    public static let legacyProductFolderName = "WyvernLegacy"
    public static let copyrightNotice = "Copyright 2026 Wyvern Contributors"
    public static let marketingVersion = "0.1.0"
    public static let buildVersion = "1"
    public static let bookmarksFileName = "bookmarks.json"
    public static let terminalBookmarksFileName = "terminal-bookmarks.json"
    public static let mediaPermissionsFileName = "media-permissions.json"
    public static let sitePermissionsFileName = "site-permissions.json"
    /// Shown on the Welcome step and in About. The only place this sentence lives.
    /// Uses the legal product name, not the short Dock name.
    public static let trademarkFootnote =
        "\(productName) is an independent open-source project and is not affiliated with, endorsed by, or sponsored by any other browser vendor. All product names and trademarks mentioned belong to their respective owners."
    public static let faviconCacheDirectoryName = "favicon-cache"
    public static let defaultsMigrationMarkerKey = "legacy.data.migrated"

    /// Bundle id of the running app, or `fallbackBundleIdentifier` in tests and tools.
    public static var bundleIdentifier: String {
        if let id = Bundle.main.bundleIdentifier, id == fallbackBundleIdentifier {
            return id
        }
        if let id = Bundle.main.object(forInfoDictionaryKey: kCFBundleIdentifierKey as String) as? String,
           id == fallbackBundleIdentifier {
            return id
        }
        return fallbackBundleIdentifier
    }

    public static var settingsDefaultsKey: String {
        "\(bundleIdentifier).settings"
    }

    public static var gitCommit: String {
        stringFromInfo("WyvernGitCommit")
    }

    /// Built-in update feed (`latest.json` or a Gitea comments API URL). Empty when not configured.
    public static var updateFeedURL: String {
        stringFromInfo("WyvernUpdateFeedURL")
    }

    public static var updatePublicKey: String {
        stringFromInfo("WyvernUpdatePublicKey")
    }

    public static var dmgBasename: String {
        let value = stringFromInfo("WyvernDMGBasename")
        return value.isEmpty ? "WyvernBrowser" : value
    }

    public static var bundleVersion: String {
        let value = stringFromInfo("CFBundleVersion")
        return value.isEmpty ? buildVersion : value
    }

    public static var shortVersion: String {
        let value = stringFromInfo("CFBundleShortVersionString")
        return value.isEmpty ? marketingVersion : value
    }

    private static func stringFromInfo(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public static var legacySettingsDefaultsKey: String {
        "\(legacyBundleIdentifier).settings"
    }

    /// Directory that holds bookmarks, settings sidecars, and the icon cache.
    public static var applicationSupportDirectory: URL {
        applicationSupportRoot().appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static func applicationSupportRoot() -> URL {
        let roots = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return roots.first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    /// Previous Application Support folders, preferred first.
    public static func legacyDataDirectories(applicationSupport: URL) -> [URL] {
        [
            applicationSupport.appendingPathComponent(legacyBundleIdentifier, isDirectory: true),
            applicationSupport.appendingPathComponent(legacyProductFolderName, isDirectory: true)
        ]
    }
}
