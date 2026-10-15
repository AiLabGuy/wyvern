// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class InternalPageTests: XCTestCase {
    func testParseRoundTrip() throws {
        let bookmarks = try XCTUnwrap(URL(string: "WYVERN://Bookmarks"))
        XCTAssertEqual(InternalPage.parse(bookmarks), .bookmarks)
        XCTAssertEqual(InternalPage.parse(InternalPage.newTab.url), .newTab)
        let other = try XCTUnwrap(URL(string: "wyvern://other"))
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
        XCTAssertEqual(internalParts.primary, "wyvern://")
        XCTAssertEqual(internalParts.secondary, "bookmarks")
    }

    func testHostOf() {
        XCTAssertEqual(AddressFormatting.host(of: "https://encyclopedia.example/wiki/tidal-locking"), "encyclopedia.example")
        XCTAssertEqual(AddressFormatting.host(of: "  not a url  "), "not a url")
    }

    func testUserinfoIsNotTheDisplayedHost() throws {
        let url = try XCTUnwrap(URL(string: "https://accounts.google.com@evil.example/path"))
        let parts = AddressFormatting.parts(for: url)
        XCTAssertEqual(parts.primary, "evil.example")
        XCTAssertEqual(parts.secondary, "/path")
        XCTAssertFalse(parts.primary.contains("@"))
        XCTAssertFalse(parts.secondary.contains("@"))
    }

    func testPathDirectionalOverrideIsStripped() throws {
        let url = try XCTUnwrap(URL(string: "https://evil.example/%E2%80%AEmoc.knab"))
        let parts = AddressFormatting.parts(for: url)
        XCTAssertEqual(parts.primary, "evil.example")
        XCTAssertFalse(parts.secondary.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertFalse(parts.primary.unicodeScalars.contains { $0.value == 0x202E })
    }

    func testUnicodeHostIsPunycode() {
        XCTAssertEqual(AddressFormatting.safeHost("аррӏе.com"), "xn--80ak6aa92e.com")
        XCTAssertEqual(AddressFormatting.safeHost("example.com"), "example.com")
        XCTAssertFalse(AddressFormatting.safeHost("ev\u{202E}il.com").contains("\u{202E}"))
    }

    func testProvisionalURLStaysOffTheAddressField() {
        XCTAssertEqual(
            AddressCommit.choice(showingTypedTarget: false, loading: true),
            .keepCommitted
        )
        XCTAssertEqual(
            AddressCommit.choice(showingTypedTarget: true, loading: true),
            .keepDisplayed
        )
        XCTAssertEqual(
            AddressCommit.choice(showingTypedTarget: false, loading: false),
            .adoptCandidate
        )
    }

    func testLockOnlyForHTTPS() throws {
        XCTAssertTrue(AddressSecurity.showsLock(URL(string: "https://example.com/a")))
        XCTAssertFalse(AddressSecurity.showsLock(URL(string: "http://example.com/a")))
        XCTAssertFalse(AddressSecurity.showsLock(URL(string: "file:///tmp/a.html")))
        XCTAssertFalse(AddressSecurity.showsLock(URL(string: "blob:https://example.com/id")))
        XCTAssertFalse(AddressSecurity.showsLock(URL(string: "about:blank")))
        XCTAssertFalse(AddressSecurity.showsLock(nil))
    }

    func testVeryLongHostKeepsTheRegistrableEnd() {
        let padded = String(repeating: "a", count: 60) + ".evil.example"
        XCTAssertGreaterThan(padded.count, 64)
        XCTAssertEqual(AddressFormatting.safeHost(padded), "…evil.example")
        XCTAssertEqual(AddressFormatting.safeHost("encyclopedia.example"), "encyclopedia.example")
    }
}
