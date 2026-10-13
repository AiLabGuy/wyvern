// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import App1Core

final class InternalPageTests: XCTestCase {
    func testParseRoundTrip() throws {
        let bookmarks = try XCTUnwrap(URL(string: "APP1://Bookmarks"))
        XCTAssertEqual(InternalPage.parse(bookmarks), .bookmarks)
        XCTAssertEqual(InternalPage.parse(InternalPage.newTab.url), .newTab)
        let other = try XCTUnwrap(URL(string: "app1://other"))
        XCTAssertNil(InternalPage.parse(other))
        let web = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertNil(InternalPage.parse(web))
    }

    func testAddressSplit() throws {
        let article = try XCTUnwrap(URL(string: "https://encyclopedia.example/wiki/tidal-locking"))
        let parts = AddressFormatting.parts(for: article)
        XCTAssertEqual(parts.primary, "encyclopedia.example")
        XCTAssertEqual(parts.secondary, "/wiki/tidal-locking")

        let query = try XCTUnwrap(URL(string: "https://example.com/a?q=1#section"))
        let queried = AddressFormatting.parts(for: query)
        XCTAssertEqual(queried.primary, "example.com")
        XCTAssertEqual(queried.secondary, "/a?q=1")

        let port = try XCTUnwrap(URL(string: "https://example.com:8443/a"))
        let withPort = AddressFormatting.parts(for: port)
        XCTAssertEqual(withPort.primary, "example.com:8443")
        XCTAssertEqual(withPort.secondary, "/a")

        let internalParts = AddressFormatting.parts(for: InternalPage.bookmarks.url)
        XCTAssertEqual(internalParts.primary, "app1://")
        XCTAssertEqual(internalParts.secondary, "bookmarks")
    }

    func testHostOf() {
        XCTAssertEqual(AddressFormatting.host(of: "https://encyclopedia.example/wiki/tidal-locking"), "encyclopedia.example")
        XCTAssertEqual(AddressFormatting.host(of: "  not a url  "), "not a url")
    }
}
