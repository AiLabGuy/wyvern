// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import App1Core

final class LaunchArgumentsTests: XCTestCase {
    func testAbsentFlagsLeaveTheNormalLaunch() {
        let config = LaunchArguments.parse(["/Applications/Wyvern Browser.app/Contents/MacOS/Wyvern Browser"])
        XCTAssertEqual(config, .none)
    }

    func testScreenshotFlagSet() {
        let config = LaunchArguments.parse([
            "App1",
            "--app1-data-dir", "/var/tmp/app1-data",
            "--app1-appearance", "dark",
            "--app1-open", "app1://bookmarks",
            "--app1-window-size", "1360x830",
            "--app1-print-window-id",
            "--app1-skip-engine-chooser"
        ])
        XCTAssertEqual(config.dataDirectory, "/var/tmp/app1-data")
        XCTAssertEqual(config.appearance, .dark)
        XCTAssertEqual(config.openTarget, "app1://bookmarks")
        XCTAssertEqual(config.windowWidth, 1360)
        XCTAssertEqual(config.windowHeight, 830)
        XCTAssertTrue(config.printWindowID)
        XCTAssertTrue(config.skipEngineChooser)
        XCTAssertNil(config.downloadsDirectory)
        XCTAssertFalse(config.showDownloads)
        XCTAssertFalse(config.bench)
    }

    func testBenchFlagAndOpenURLAlias() {
        let bench = LaunchArguments.parse(["App1", "--app1-bench"])
        XCTAssertTrue(bench.bench)
        let openURL = LaunchArguments.parse([
            "App1",
            "--app1-open-url", "http://127.0.0.1:9/bench.html"
        ])
        XCTAssertEqual(openURL.openTarget, "http://127.0.0.1:9/bench.html")
        XCTAssertFalse(openURL.bench)
    }

    func testDownloadsFlags() {
        let config = LaunchArguments.parse([
            "App1",
            "--app1-downloads-dir", "/var/tmp/app1-dl",
            "--app1-show-downloads"
        ])
        XCTAssertEqual(config.downloadsDirectory, "/var/tmp/app1-dl")
        XCTAssertTrue(config.showDownloads)
    }

    func testAppearanceAndSizeValidation() {
        XCTAssertEqual(
            LaunchArguments.parse(["App1", "--app1-appearance", "Light"]).appearance,
            .light
        )
        XCTAssertEqual(
            LaunchArguments.parse(["App1", "--app1-appearance", "Dark"]).appearance,
            .dark
        )
        XCTAssertNil(LaunchArguments.parse(["App1", "--app1-appearance", "purple"]).appearance)
        let broken = LaunchArguments.parse(["App1", "--app1-window-size", "0x10"])
        XCTAssertNil(broken.windowWidth)
        XCTAssertNil(broken.windowHeight)
    }

    func testShowSetupFlag() {
        let config = LaunchArguments.parse(["App1", "--app1-show-setup"])
        XCTAssertTrue(config.showSetup)
        XCTAssertFalse(config.skipEngineChooser)
        XCTAssertFalse(LaunchArguments.parse(["App1"]).showSetup)
    }

    func testAppearanceSystemValue() {
        XCTAssertEqual(
            LaunchArguments.parse(["App1", "--app1-appearance", "system"]).appearance,
            .system
        )
    }

    func testValueThatLooksLikeAFlagIsNotConsumed() {
        let config = LaunchArguments.parse([
            "App1",
            "--app1-data-dir",
            "--app1-open", "app1://newtab"
        ])
        XCTAssertNil(config.dataDirectory)
        XCTAssertEqual(config.openTarget, "app1://newtab")
    }
}
