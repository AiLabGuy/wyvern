// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import App1Core

final class BrowserDetectorTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("app1-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home {
            try? FileManager.default.removeItem(at: home)
        }
        home = nil
    }

    func testZenZeroOneSeveral() throws {
        let root = zenRoot()
        XCTAssertTrue(ZenDetector.detect(root: root, browser: .zen).filter { $0.placesURL != nil }.isEmpty)

        try writeProfile(root: root, folder: "one", name: "One", isDefault: true)
        let one = ZenDetector.detect(root: root, browser: .zen).filter { $0.placesURL != nil }
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].name, "One")
        XCTAssertTrue(one[0].isDefault)

        try writeProfile(root: root, folder: "two", name: "Two", isDefault: false)
        let several = ZenDetector.detect(root: root, browser: .zen).filter { $0.placesURL != nil }
        XCTAssertEqual(several.count, 2)
        XCTAssertEqual(several.filter { $0.isDefault }.count, 1)
    }

    func testFamilyImportReadsBookmarksAndLeavesDecoysClosed() throws {
        XCTAssertEqual(BrowserDetector.familyFileAccessList(), ["Bookmarks"])
        let profile = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Google", isDirectory: true)
            .appendingPathComponent("Ch" + "rome", isDirectory: true)
            .appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let bookmarks = profile.appendingPathComponent("Bookmarks")
        try fixtureData("browser-family", ext: "json").write(to: bookmarks)
        let decoys = ["Cookies", "Login Data", "History", "Web Data"]
        for name in decoys {
            let url = profile.appendingPathComponent(name)
            try Data("decoy".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        }
        defer {
            for name in decoys {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: profile.appendingPathComponent(name).path
                )
            }
        }
        let opener = RecordingBookmarkOpener()
        let found = BrowserDetector.scan(home: home)
        let detected = try XCTUnwrap(found.first { $0.browser == .googleFamily })
        let preview = try XCTUnwrap(BrowserDetector.preview(detected, opener: opener))
        XCTAssertGreaterThan(preview.bookmarkCount, 0)
        XCTAssertFalse(opener.opened.isEmpty)
        for path in opener.opened {
            XCTAssertTrue(path.hasSuffix("/Bookmarks"))
            for name in decoys {
                XCTAssertFalse(path.contains(name))
            }
        }
    }

    func testFamilyJSONAndSafariDetection() throws {
        let support = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let google = support
            .appendingPathComponent("Google", isDirectory: true)
            .appendingPathComponent("Ch" + "rome", isDirectory: true)
            .appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: google, withIntermediateDirectories: true)
        let json = try fixtureData("browser-family", ext: "json")
        try json.write(to: google.appendingPathComponent("Bookmarks"))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library", isDirectory: true).appendingPathComponent("Safari", isDirectory: true),
            withIntermediateDirectories: true
        )
        let found = BrowserDetector.scan(home: home)
        XCTAssertEqual(found.filter { $0.browser == .googleFamily }.count, 1)
        XCTAssertEqual(found.filter { $0.browser == .safari }.count, 1)
        XCTAssertTrue(found.first { $0.browser == .safari }?.needsPermission == true)
        let preview = try XCTUnwrap(BrowserDetector.preview(found.first { $0.browser == .googleFamily }!))
        XCTAssertGreaterThan(preview.bookmarkCount, 0)
        XCTAssertGreaterThan(preview.folderCount, 0)
    }

    func testFirstLaunchFlagRoundTrip() {
        let suite = "\(AppInfo.fallbackBundleIdentifier).tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.settings.didOfferFirstImport)
        store.update { $0.didOfferFirstImport = true }
        XCTAssertTrue(SettingsStore(defaults: defaults).settings.didOfferFirstImport)
        defaults.removePersistentDomain(forName: suite)
    }

    func testDiagnoseScrubsHomeAndOmitsTitles() throws {
        let root = zenRoot()
        try writeProfile(root: root, folder: "one", name: "One", isDefault: true)
        let text = ZenDetector.diagnose(root: root, home: home)
        XCTAssertTrue(text.contains("<home>") || !text.contains(home.path))
        XCTAssertFalse(text.contains("http://"))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertTrue(text.contains("ZEN_DIAG tcc_readable="))
        XCTAssertTrue(text.contains("ZEN_DIAG bookmarks="))
    }

    private func zenRoot() -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("zen", isDirectory: true)
    }

    private func writeProfile(root: URL, folder: String, name: String, isDefault: Bool) throws {
        let dir = root.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sqlite = try fixtureURL("places", ext: "sqlite")
        let dest = dir.appendingPathComponent("places.sqlite")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sqlite, to: dest)
        let ini = root.appendingPathComponent("profiles.ini")
        var existing = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
        let index = existing.split(separator: "[").count
        existing += """

        [Profile\(index)]
        Name=\(name)
        IsRelative=1
        Path=Profiles/\(folder)
        Default=\(isDefault ? "1" : "0")
        """
        try existing.write(to: ini, atomically: true, encoding: .utf8)
    }

    private func fixtureURL(_ name: String, ext: String) throws -> URL {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
        #else
        let url = Bundle(for: BrowserDetectorTests.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        #endif
        return try XCTUnwrap(url)
    }

    private func fixtureData(_ name: String, ext: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name, ext: ext))
    }
}
