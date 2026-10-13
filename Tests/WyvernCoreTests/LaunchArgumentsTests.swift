// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class LaunchArgumentsTests: XCTestCase {
    func testAbsentFlagsLeaveTheNormalLaunch() {
        let config = LaunchArguments.parse(["/Applications/Wyvern Browser.app/Contents/MacOS/Wyvern Browser"])
        XCTAssertEqual(config, .none)
    }

    func testScreenshotFlagSet() {
        let config = LaunchArguments.parse([
            "Wyvern",
            "--wyvern-data-dir", "/var/tmp/wyvern-data",
            "--wyvern-appearance", "dark",
            "--wyvern-open", "wyvern://bookmarks",
            "--wyvern-window-size", "1360x830",
            "--wyvern-print-window-id",
            "--wyvern-skip-engine-chooser"
        ])
        XCTAssertEqual(config.dataDirectory, "/var/tmp/wyvern-data")
        XCTAssertEqual(config.appearance, .dark)
        XCTAssertEqual(config.openTarget, "wyvern://bookmarks")
        XCTAssertEqual(config.windowWidth, 1360)
        XCTAssertEqual(config.windowHeight, 830)
        XCTAssertTrue(config.printWindowID)
        XCTAssertTrue(config.skipEngineChooser)
        XCTAssertNil(config.downloadsDirectory)
        XCTAssertFalse(config.showDownloads)
        XCTAssertFalse(config.bench)
    }

    func testBenchFlagAndOpenURLAlias() {
        let bench = LaunchArguments.parse(["Wyvern", "--wyvern-bench"])
        XCTAssertTrue(bench.bench)
        let openURL = LaunchArguments.parse([
            "Wyvern",
            "--wyvern-open-url", "http://127.0.0.1:9/bench.html"
        ])
        XCTAssertEqual(openURL.openTarget, "http://127.0.0.1:9/bench.html")
        XCTAssertFalse(openURL.bench)
    }

    func testDownloadsFlags() {
        let config = LaunchArguments.parse([
            "Wyvern",
            "--wyvern-downloads-dir", "/var/tmp/wyvern-dl",
            "--wyvern-show-downloads"
        ])
        XCTAssertEqual(config.downloadsDirectory, "/var/tmp/wyvern-dl")
        XCTAssertTrue(config.showDownloads)
    }

    func testAppearanceAndSizeValidation() {
        XCTAssertEqual(
            LaunchArguments.parse(["Wyvern", "--wyvern-appearance", "Light"]).appearance,
            .light
        )
        XCTAssertEqual(
            LaunchArguments.parse(["Wyvern", "--wyvern-appearance", "Dark"]).appearance,
            .dark
        )
        XCTAssertNil(LaunchArguments.parse(["Wyvern", "--wyvern-appearance", "purple"]).appearance)
        let broken = LaunchArguments.parse(["Wyvern", "--wyvern-window-size", "0x10"])
        XCTAssertNil(broken.windowWidth)
        XCTAssertNil(broken.windowHeight)
    }

    func testShowSetupFlag() {
        let config = LaunchArguments.parse(["Wyvern", "--wyvern-show-setup"])
        XCTAssertTrue(config.showSetup)
        XCTAssertFalse(config.skipEngineChooser)
        XCTAssertFalse(LaunchArguments.parse(["Wyvern"]).showSetup)
    }

    func testAppearanceSystemValue() {
        XCTAssertEqual(
            LaunchArguments.parse(["Wyvern", "--wyvern-appearance", "system"]).appearance,
            .system
        )
    }

    func testValueThatLooksLikeAFlagIsNotConsumed() {
        let config = LaunchArguments.parse([
            "Wyvern",
            "--wyvern-data-dir",
            "--wyvern-open", "wyvern://newtab"
        ])
        XCTAssertNil(config.dataDirectory)
        XCTAssertEqual(config.openTarget, "wyvern://newtab")
    }
}
