// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class FaviconPolicyTests: XCTestCase {
    private let page = URL(string: "https://example.com/docs/index.html") ?? URL(fileURLWithPath: "/")

    func testRelativeHrefStaysOnThePageHost() throws {
        let url = try XCTUnwrap(FaviconPolicy.iconURL(pageURL: page, linkHref: "/icons/app.png"))
        XCTAssertEqual(url.absoluteString, "https://example.com/icons/app.png")
    }

    func testSameHostAbsoluteHrefIsAccepted() throws {
        let url = try XCTUnwrap(FaviconPolicy.iconURL(pageURL: page, linkHref: "https://example.com/a.ico"))
        XCTAssertEqual(url.absoluteString, "https://example.com/a.ico")
    }

    func testOtherHostFallsBackToFaviconIco() throws {
        let url = try XCTUnwrap(
            FaviconPolicy.iconURL(pageURL: page, linkHref: "https://cdn.example.net/icon.png")
        )
        XCTAssertEqual(url.absoluteString, "https://example.com/favicon.ico")
    }

    func testEmptyHrefFallsBack() throws {
        let url = try XCTUnwrap(FaviconPolicy.iconURL(pageURL: page, linkHref: "  "))
        XCTAssertEqual(url.absoluteString, "https://example.com/favicon.ico")
    }

    func testProtocolRelativeOtherHostFallsBack() throws {
        let url = try XCTUnwrap(FaviconPolicy.iconURL(pageURL: page, linkHref: "//icons.example.net/x.png"))
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.path, "/favicon.ico")
    }

    func testDataAndJavascriptHrefsFallBack() throws {
        let dataURL = try XCTUnwrap(FaviconPolicy.iconURL(pageURL: page, linkHref: "data:image/png,aaaa"))
        XCTAssertEqual(dataURL.absoluteString, "https://example.com/favicon.ico")
        let scriptURL = try XCTUnwrap(FaviconPolicy.iconURL(pageURL: page, linkHref: "javascript:alert(1)"))
        XCTAssertEqual(scriptURL.absoluteString, "https://example.com/favicon.ico")
    }

    func testHTTPIconOnHTTPSPageFallsBack() throws {
        let url = try XCTUnwrap(FaviconPolicy.iconURL(pageURL: page, linkHref: "http://example.com/icon.png"))
        XCTAssertEqual(url.absoluteString, "https://example.com/favicon.ico")
    }

    func testHTTPIconOnHTTPPageIsAccepted() throws {
        let httpPage = try XCTUnwrap(URL(string: "http://example.com/index.html"))
        let url = try XCTUnwrap(FaviconPolicy.iconURL(pageURL: httpPage, linkHref: "http://example.com/icon.png"))
        XCTAssertEqual(url.absoluteString, "http://example.com/icon.png")
    }

    func testHTTPPageFallbackStaysHTTPS() throws {
        let httpPage = try XCTUnwrap(URL(string: "http://example.com/a"))
        let url = try XCTUnwrap(FaviconPolicy.iconURL(pageURL: httpPage, linkHref: nil))
        XCTAssertEqual(url.absoluteString, "https://example.com/favicon.ico")
    }

    func testNonHTTPPageHasNoIcon() {
        guard let about = URL(string: "about:blank") else {
            XCTFail("about:blank")
            return
        }
        XCTAssertNil(FaviconPolicy.iconURL(pageURL: about, linkHref: "/favicon.ico"))
    }
}
