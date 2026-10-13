// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class DataMigrationTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("wyvern-migrate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? fileManager.removeItem(at: root)
        }
        root = nil
    }

    func testNoneIsFresh() {
        let old = root.appendingPathComponent(AppInfo.legacyBundleIdentifier, isDirectory: true)
        let dest = root.appendingPathComponent(AppInfo.fallbackBundleIdentifier, isDirectory: true)
        let result = DataMigration.migrateFiles(
            legacyCandidates: AppInfo.legacyDataDirectories(applicationSupport: root),
            destination: dest,
            fileManager: fileManager,
            skip: false
        )
        XCTAssertEqual(result, .skippedNoLegacy)
        XCTAssertFalse(fileManager.fileExists(atPath: old.path))
        XCTAssertFalse(fileManager.fileExists(atPath: dest.path))
    }

    func testOldOnlyMigratesThenRemovesSource() throws {
        let old = root.appendingPathComponent(AppInfo.legacyBundleIdentifier, isDirectory: true)
        let dest = root.appendingPathComponent(AppInfo.fallbackBundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: old, withIntermediateDirectories: true)
        let bookmarks = old.appendingPathComponent(AppInfo.bookmarksFileName)
        let media = old.appendingPathComponent(AppInfo.mediaPermissionsFileName)
        try Data("bookmarks".utf8).write(to: bookmarks)
        try Data("media".utf8).write(to: media)
        let cache = old.appendingPathComponent(AppInfo.faviconCacheDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: cache.appendingPathComponent("icon.bin"))

        let result = DataMigration.migrateFiles(
            legacyCandidates: AppInfo.legacyDataDirectories(applicationSupport: root),
            destination: dest,
            fileManager: fileManager,
            skip: false
        )
        XCTAssertEqual(result, .migrated(from: AppInfo.legacyBundleIdentifier))
        XCTAssertFalse(fileManager.fileExists(atPath: old.path))
        XCTAssertTrue(fileManager.fileExists(atPath: dest.appendingPathComponent(AppInfo.bookmarksFileName).path))
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent(AppInfo.bookmarksFileName), encoding: .utf8),
            "bookmarks"
        )
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent(AppInfo.mediaPermissionsFileName), encoding: .utf8),
            "media"
        )
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent(AppInfo.faviconCacheDirectoryName).appendingPathComponent("icon.bin"), encoding: .utf8),
            "icon"
        )
    }

    func testProductFolderLegacyIsUsedWhenBundleFolderIsMissing() throws {
        let old = root.appendingPathComponent(AppInfo.legacyProductFolderName, isDirectory: true)
        let dest = root.appendingPathComponent(AppInfo.fallbackBundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("from-wyvern-folder".utf8).write(to: old.appendingPathComponent(AppInfo.bookmarksFileName))
        let result = DataMigration.migrateFiles(
            legacyCandidates: AppInfo.legacyDataDirectories(applicationSupport: root),
            destination: dest,
            fileManager: fileManager,
            skip: false
        )
        XCTAssertEqual(result, .migrated(from: AppInfo.legacyProductFolderName))
        XCTAssertFalse(fileManager.fileExists(atPath: old.path))
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent(AppInfo.bookmarksFileName), encoding: .utf8),
            "from-wyvern-folder"
        )
    }

    func testBothExistIsNoOp() throws {
        let old = root.appendingPathComponent(AppInfo.legacyBundleIdentifier, isDirectory: true)
        let dest = root.appendingPathComponent(AppInfo.fallbackBundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: old, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent(AppInfo.bookmarksFileName))
        try Data("new".utf8).write(to: dest.appendingPathComponent(AppInfo.bookmarksFileName))
        let result = DataMigration.migrateFiles(
            legacyCandidates: AppInfo.legacyDataDirectories(applicationSupport: root),
            destination: dest,
            fileManager: fileManager,
            skip: false
        )
        XCTAssertEqual(result, .skippedDestinationExists)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent(AppInfo.bookmarksFileName), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent(AppInfo.bookmarksFileName), encoding: .utf8), "new")
    }

    func testOverrideSkipsMigration() throws {
        let old = root.appendingPathComponent(AppInfo.legacyBundleIdentifier, isDirectory: true)
        let dest = root.appendingPathComponent(AppInfo.fallbackBundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent(AppInfo.bookmarksFileName))
        let result = DataMigration.migrateFiles(
            legacyCandidates: AppInfo.legacyDataDirectories(applicationSupport: root),
            destination: dest,
            fileManager: fileManager,
            skip: true
        )
        XCTAssertEqual(result, .skippedOverride)
        XCTAssertTrue(fileManager.fileExists(atPath: old.appendingPathComponent(AppInfo.bookmarksFileName).path))
        XCTAssertFalse(fileManager.fileExists(atPath: dest.path))
    }

    func testDefaultsMigrateOnceWithMarker() throws {
        let legacyName = "org.placeholder.wyvern.migrate-test.\(UUID().uuidString)"
        let currentName = "com.example.wyvern.migrate-test.\(UUID().uuidString)"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacyName))
        let current = try XCTUnwrap(UserDefaults(suiteName: currentName))
        legacy.removePersistentDomain(forName: legacyName)
        current.removePersistentDomain(forName: currentName)
        let payload = Data("settings-json".utf8)
        legacy.set(payload, forKey: AppInfo.legacySettingsDefaultsKey)
        legacy.set("keep-me", forKey: "extra.flag")
        legacy.synchronize()

        let first = DataMigration.migrateDefaults(
            legacy: legacy,
            current: current,
            legacyDomainName: legacyName,
            legacySettingsKey: AppInfo.legacySettingsDefaultsKey,
            currentSettingsKey: AppInfo.settingsDefaultsKey
        )
        XCTAssertTrue(first)
        XCTAssertEqual(current.data(forKey: AppInfo.settingsDefaultsKey), payload)
        XCTAssertEqual(current.string(forKey: "extra.flag"), "keep-me")
        XCTAssertTrue(current.bool(forKey: AppInfo.defaultsMigrationMarkerKey))

        current.set(Data("already".utf8), forKey: AppInfo.settingsDefaultsKey)
        let second = DataMigration.migrateDefaults(
            legacy: legacy,
            current: current,
            legacyDomainName: legacyName,
            legacySettingsKey: AppInfo.legacySettingsDefaultsKey,
            currentSettingsKey: AppInfo.settingsDefaultsKey
        )
        XCTAssertFalse(second)
        XCTAssertEqual(current.data(forKey: AppInfo.settingsDefaultsKey), Data("already".utf8))

        legacy.removePersistentDomain(forName: legacyName)
        current.removePersistentDomain(forName: currentName)
    }
}
