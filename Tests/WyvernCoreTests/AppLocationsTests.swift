// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class AppLocationsTests: XCTestCase {
    override func tearDown() {
        AppLocations.setDataDirectory(nil)
        AppLocations.setDownloadsDirectory(nil)
        super.tearDown()
    }

    func testOverrideAndSuiteName() {
        let directory = URL(fileURLWithPath: "/var/tmp/wyvern-locations-test", isDirectory: true)
        AppLocations.setDataDirectory(directory)
        XCTAssertEqual(AppLocations.dataDirectory.standardizedFileURL, directory.standardizedFileURL)
        let name = AppLocations.suiteName(for: directory)
        XCTAssertTrue(name.hasPrefix("\(AppInfo.bundleIdentifier).data."))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.lowercased().contains("tmp"))
        XCTAssertEqual(name, AppLocations.suiteName(for: directory))
        XCTAssertEqual(AppLocations.defaultsSuiteName, name)
        AppLocations.setDataDirectory(nil)
        XCTAssertNil(AppLocations.defaultsSuiteName)
        XCTAssertEqual(
            AppLocations.dataDirectory.standardizedFileURL,
            AppInfo.applicationSupportDirectory.standardizedFileURL
        )
    }

    func testDownloadsDirectoryOverride() {
        let directory = URL(fileURLWithPath: "/var/tmp/wyvern-downloads-test", isDirectory: true)
        AppLocations.setDownloadsDirectory(directory)
        XCTAssertEqual(AppLocations.downloadsDirectory.standardizedFileURL, directory.standardizedFileURL)
        AppLocations.setDownloadsDirectory(nil)
        XCTAssertEqual(
            AppLocations.downloadsDirectory.lastPathComponent,
            "Downloads"
        )
    }
}
