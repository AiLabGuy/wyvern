// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore
#if canImport(WebKit)
import WebKit
#endif

final class SafariUserAgentTests: XCTestCase {
    func testApplicationNameMatchesSafariFormat() {
        XCTAssertEqual(
            SafariUserAgent.applicationName(safariVersion: "27.0.1", osMajor: 27),
            "Version/27.0.1 Safari/605.1.15"
        )
        XCTAssertEqual(
            SafariUserAgent.applicationName(safariVersion: "18.6", osMajor: 15),
            "Version/18.6 Safari/605.1.15"
        )
    }

    func testCurrentHasSafariShapeAndNoAppToken() {
        let name = SafariUserAgent.current
        let pattern = #"^Version/[0-9]{1,4}(\.[0-9]{1,4}){0,2} Safari/605\.1\.15$"#
        XCTAssertNotNil(name.range(of: pattern, options: .regularExpression), name)
        for token in ["Wyvern", "Wyvern", "wyvern", "wyvern"] {
            XCTAssertFalse(name.contains(token), name)
        }
    }

    func testMalformedVersionsUseTheFallback() {
        for bad in [nil, "", " ", "abc", "27.0.1.2", "27..1", "27.0 Wyvern", "1/2", "12345.0", "２７.0"] {
            XCTAssertNil(SafariUserAgent.sanitized(bad), String(describing: bad))
            XCTAssertEqual(
                SafariUserAgent.applicationName(safariVersion: bad, osMajor: 15),
                "Version/18.0 Safari/605.1.15",
                String(describing: bad)
            )
        }
        XCTAssertEqual(SafariUserAgent.sanitized(" 27.0 "), "27.0")
        XCTAssertEqual(SafariUserAgent.sanitized("17"), "17")
    }

    func testFallbackFollowsTheMacOSRelease() {
        XCTAssertEqual(SafariUserAgent.fallbackVersion(osMajor: 13), "16.0")
        XCTAssertEqual(SafariUserAgent.fallbackVersion(osMajor: 14), "17.0")
        XCTAssertEqual(SafariUserAgent.fallbackVersion(osMajor: 15), "18.0")
        XCTAssertEqual(SafariUserAgent.fallbackVersion(osMajor: 26), "26.0")
        XCTAssertEqual(SafariUserAgent.fallbackVersion(osMajor: 27), "27.0")
    }

    func testInstalledVersionReadsAPlistAndSkipsMissingOrBadOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.plist")
        let good = dir.appendingPathComponent("good.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "x y"], format: .xml, options: 0).write(to: bad)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "26.2"], format: .xml, options: 0).write(to: good)
        let missing = dir.appendingPathComponent("missing.plist").path
        XCTAssertEqual(SafariUserAgent.installedSafariVersion(paths: [missing, bad.path, good.path]), "26.2")
        XCTAssertNil(SafariUserAgent.installedSafariVersion(paths: [missing, bad.path]))
    }

    #if canImport(WebKit)
    @MainActor
    func testConfigurationGetsTheApplicationName() {
        let configuration = WKWebViewConfiguration()
        SafariUserAgent.apply(to: configuration)
        XCTAssertEqual(configuration.applicationNameForUserAgent, SafariUserAgent.current)
        XCTAssertTrue(configuration.applicationNameForUserAgent?.hasPrefix("Version/") == true)
    }

    @MainActor
    func testPopupCopyKeepsTheApplicationName() throws {
        let opener = WKWebViewConfiguration()
        SafariUserAgent.apply(to: opener)
        let copy = try XCTUnwrap(opener.copy() as? WKWebViewConfiguration)
        XCTAssertEqual(copy.applicationNameForUserAgent, SafariUserAgent.current)
    }

    @MainActor
    func testWebViewUserAgentEndsWithSafariTokens() {
        let configuration = WKWebViewConfiguration()
        SafariUserAgent.apply(to: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        XCTAssertNil(webView.customUserAgent.flatMap { $0.isEmpty ? nil : $0 })
        let expectation = expectation(description: "navigator.userAgent")
        webView.evaluateJavaScript("navigator.userAgent") { value, _ in
            let agent = value as? String ?? ""
            XCTAssertTrue(agent.hasPrefix("Mozilla/5.0 (Macintosh;"), agent)
            XCTAssertTrue(agent.contains("AppleWebKit/605.1.15 (KHTML, like Gecko)"), agent)
            XCTAssertTrue(agent.hasSuffix(" " + SafariUserAgent.current), agent)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }
    #endif
}
