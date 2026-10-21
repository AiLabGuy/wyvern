// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class InputResolverTests: XCTestCase {
    private let resolver = InputResolver(engine: .duckDuckGo)

    func testHTTPSUnchanged() {
        let url = resolver.resolve("https://example.com/a?b=1")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "example.com")
        XCTAssertEqual(url?.path, "/a")
    }

    func testHTTPUnchanged() {
        let url = resolver.resolve("http://example.com/path")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "example.com")
        XCTAssertEqual(url?.path, "/path")
    }

    func testFileUnchanged() {
        let url = resolver.resolve("file:///tmp/a.html")
        XCTAssertEqual(url?.scheme, "file")
        XCTAssertEqual(url?.path, "/tmp/a.html")
    }

    func testAboutUnchanged() {
        let url = resolver.resolve("about:blank")
        XCTAssertEqual(url?.scheme, "about")
        XCTAssertEqual(url?.absoluteString, "about:blank")
    }

    func testUppercaseHTTPSchemeIsNotRewrittenAsSearch() {
        let url = resolver.resolve("  HTTP://Example.COM/x  ")
        XCTAssertEqual(url?.scheme?.lowercased(), "http")
        XCTAssertEqual(url?.host?.lowercased(), "example.com")
    }

    func testDomainGetsHTTPS() {
        let url = resolver.resolve("example.com")
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testDomainWithPathGetsHTTPS() {
        let url = resolver.resolve("example.com/docs/index.html")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "example.com")
        XCTAssertEqual(url?.path, "/docs/index.html")
    }

    func testLocalhost() {
        let url = resolver.resolve("localhost")
        XCTAssertEqual(url?.absoluteString, "http://localhost")
    }

    func testLocalhostPort() {
        let url = resolver.resolve("localhost:8080")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "localhost")
        XCTAssertEqual(url?.port, 8080)
    }

    func testLocalhostPortAndPath() {
        let url = resolver.resolve("LocalHost:3000/app")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host?.lowercased(), "localhost")
        XCTAssertEqual(url?.port, 3000)
        XCTAssertEqual(url?.path, "/app")
    }

    func testIPv4() {
        let url = resolver.resolve("127.0.0.1")
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1")
    }

    func testLoopbackWithPortAndPathUsesHTTP() {
        let url = resolver.resolve("127.0.0.1:9/plain.html")
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:9/plain.html")
    }

    // Scheme-less IP and host:port input. A LAN address with https:// fails the TLS handshake,
    // and the bar looked like it did nothing on Enter.
    func testPrivateIPv4WithPortUsesHTTP() {
        let url = resolver.resolve("10.0.0.5:8140")
        XCTAssertEqual(url?.absoluteString, "http://10.0.0.5:8140")
        XCTAssertEqual(url?.host, "10.0.0.5")
        XCTAssertEqual(url?.port, 8140)
    }

    func testIPv4WithPort() {
        let url = resolver.resolve("192.168.1.20:3000")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "192.168.1.20")
        XCTAssertEqual(url?.port, 3000)
    }

    func testBareIPv4UsesHTTP() {
        XCTAssertEqual(resolver.resolve("192.168.1.1")?.absoluteString, "http://192.168.1.1")
        XCTAssertEqual(resolver.resolve("10.0.0.5")?.absoluteString, "http://10.0.0.5")
    }

    func testIPv4WithPortPathQueryAndFragment() {
        XCTAssertEqual(resolver.resolve("192.168.1.1:8080/admin")?.absoluteString, "http://192.168.1.1:8080/admin")
        XCTAssertEqual(resolver.resolve("10.0.0.5:8080?tab=2")?.absoluteString, "http://10.0.0.5:8080?tab=2")
        XCTAssertEqual(resolver.resolve("10.0.0.5/status#top")?.absoluteString, "http://10.0.0.5/status#top")
    }

    func testIPv4OnPort443StaysHTTPS() {
        XCTAssertEqual(resolver.resolve("192.168.1.1:443")?.absoluteString, "https://192.168.1.1:443")
    }

    func testBracketedIPv6UsesHTTP() {
        XCTAssertEqual(resolver.resolve("[::1]")?.absoluteString, "http://[::1]")
        let url = resolver.resolve("[::1]:8080")
        XCTAssertEqual(url?.absoluteString, "http://[::1]:8080")
        XCTAssertEqual(url?.port, 8080)
        XCTAssertEqual(resolver.resolve("[fe80::1]:3000/x")?.absoluteString, "http://[fe80::1]:3000/x")
        XCTAssertEqual(resolver.resolve("[2001:db8::5]")?.scheme, "http")
    }

    func testMalformedIPv6IsSearch() {
        XCTAssertEqual(resolver.resolve("[not:v6]")?.host, "duckduckgo.com")
        XCTAssertEqual(resolver.resolve("[::1")?.host, "duckduckgo.com")
        XCTAssertEqual(resolver.resolve("[::1]:99999")?.host, "duckduckgo.com")
    }

    func testSingleLabelWithPortUsesHTTP() {
        let url = resolver.resolve("nas:5000")
        XCTAssertEqual(url?.absoluteString, "http://nas:5000")
        XCTAssertEqual(url?.host, "nas")
        XCTAssertEqual(url?.port, 5000)
        XCTAssertEqual(resolver.resolve("printer:631/admin")?.absoluteString, "http://printer:631/admin")
    }

    func testDottedNameWithPortUsesHTTP() {
        let url = resolver.resolve("git.example.lan:3000")
        XCTAssertEqual(url?.absoluteString, "http://git.example.lan:3000")
        XCTAssertEqual(resolver.resolve("example.com:443")?.scheme, "https")
    }

    func testSingleLabelWithoutPortIsStillSearch() {
        XCTAssertEqual(resolver.resolve("nas")?.host, "duckduckgo.com")
        XCTAssertEqual(resolver.resolve("weather")?.host, "duckduckgo.com")
    }

    func testColonTextThatIsNotAPortIsSearch() {
        XCTAssertEqual(resolver.resolve("note:remember")?.host, "duckduckgo.com")
        XCTAssertEqual(resolver.resolve("nas:0")?.host, "duckduckgo.com")
        XCTAssertEqual(resolver.resolve("nas:70000")?.host, "duckduckgo.com")
        XCTAssertEqual(resolver.resolve("-bad-:80")?.host, "duckduckgo.com")
        XCTAssertEqual(resolver.resolve("10.0.0.5 8080")?.host, "duckduckgo.com")
        XCTAssertEqual(resolver.resolve("what is 10.0.0.5:8080")?.host, "duckduckgo.com")
    }

    func testKnownSchemesBeforeAColonAreUnchanged() {
        XCTAssertEqual(resolver.resolve("mailto:5000")?.host, "duckduckgo.com")
        XCTAssertEqual(resolver.resolve("http://10.0.0.5:8140")?.absoluteString, "http://10.0.0.5:8140")
        XCTAssertEqual(resolver.resolve("https://192.168.1.1:8443")?.absoluteString, "https://192.168.1.1:8443")
    }

    func testWordsBecomeSearch() {
        let url = resolver.resolve("hello world")
        XCTAssertEqual(url?.host, "duckduckgo.com")
        XCTAssertTrue(url?.absoluteString.contains("q=hello%20world") == true)
    }

    func testSpacedTextWithADotIsSearch() {
        let url = resolver.resolve("what is swift.org")
        XCTAssertEqual(url?.host, "duckduckgo.com")
        XCTAssertNotEqual(url?.host, "swift.org")
    }

    func testIcarusAndWyvernRunAddressesBecomeSearch() {
        let icarus = resolver.resolve("icarus://run?cmd=ls")
        XCTAssertEqual(icarus?.host, "duckduckgo.com")
        XCTAssertNotEqual(icarus?.scheme?.lowercased(), "icarus")
        let wyvern = resolver.resolve("wyvern://run")
        XCTAssertEqual(wyvern?.host, "duckduckgo.com")
        XCTAssertNotEqual(wyvern?.scheme?.lowercased(), "wyvern")
    }

    func testJavascriptIsSearchNotANavigation() {
        let url = resolver.resolve("javascript:alert(1)")
        XCTAssertNotEqual(url?.scheme?.lowercased(), "javascript")
        XCTAssertEqual(url?.host, "duckduckgo.com")
    }

    func testDataIsSearchNotANavigation() {
        let url = resolver.resolve("data:text/html,hi")
        XCTAssertNotEqual(url?.scheme?.lowercased(), "data")
        XCTAssertEqual(url?.host, "duckduckgo.com")
    }

    func testInternalPagesResolveAndOtherWyvernHostsSearch() throws {
        let bookmarks = try XCTUnwrap(resolver.resolve("wyvern://bookmarks"))
        XCTAssertEqual(InternalPage.parse(bookmarks), .bookmarks)
        let newTab = try XCTUnwrap(resolver.resolve("WYVERN://newtab"))
        XCTAssertEqual(InternalPage.parse(newTab), .newTab)
        let other = try XCTUnwrap(resolver.resolve("wyvern://other"))
        XCTAssertEqual(other.host, "duckduckgo.com")
        XCTAssertNotEqual(other.scheme, "wyvern")
    }

    func testMailtoTypedInTheBarIsSearch() {
        let url = resolver.resolve("mailto:person@example.com")
        XCTAssertEqual(url?.host, "duckduckgo.com")
        XCTAssertNotEqual(url?.scheme, "mailto")
    }

    func testEmptyIsNil() {
        XCTAssertNil(resolver.resolve("   "))
        XCTAssertNil(resolver.resolve(""))
    }

    func testQueryEncodingRemovesReservedCharactersFromTheAllowedSet() {
        let raw = "a b&c+d=e?f#g"
        let encoded = QueryEncoding.percentEncode(raw)
        XCTAssertEqual(encoded, "a%20b%26c%2Bd%3De%3Ff%23g")
        let url = resolver.resolve(raw)
        XCTAssertTrue(url?.absoluteString.contains(encoded) == true)
        XCTAssertEqual(url?.host, "duckduckgo.com")
    }

    func testCustomEngineTemplateIsUsed() throws {
        let engine = try XCTUnwrap(SearchEngine.custom(template: "https://search.example/find?q={query}"))
        let custom = InputResolver(engine: engine)
        let url = custom.resolve("cats")
        XCTAssertEqual(url?.absoluteString, "https://search.example/find?q=cats")
    }

    func testInvalidIPv4OctetStillCountsAsADottedHost() {
        let url = resolver.resolve("999.1.1.1")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "999.1.1.1")
    }
}
