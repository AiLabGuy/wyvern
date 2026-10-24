// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class LoadFailureCopyTests: XCTestCase {
    func testCannotFindHost() {
        let copy = LoadFailureCopy.from(urlErrorCode: NSURLErrorCannotFindHost, localized: "x")
        XCTAssertEqual(copy.title, "Server not found")
        XCTAssertFalse(copy.preferSilent)
    }

    func testSecureConnectionFailed() {
        let copy = LoadFailureCopy.from(urlErrorCode: NSURLErrorServerCertificateUntrusted, localized: "bad")
        XCTAssertEqual(copy.title, "Connection not private")
    }

    func testHTMLEscapes() {
        let raw = "<script>\"&'"
        let escaped = LoadFailureCopy.escapeHTML(raw)
        XCTAssertFalse(escaped.contains("<script>"))
        XCTAssertTrue(escaped.contains("&lt;script&gt;"))
        XCTAssertTrue(escaped.contains("&quot;"))
        XCTAssertTrue(escaped.contains("&amp;"))
    }

    func testHTMLDocumentIncludesReload() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/path"))
        let copy = LoadFailureCopy(title: "Server not found", detail: "Try again.")
        let html = LoadFailureCopy.htmlDocument(copy: copy, failingURL: url)
        XCTAssertTrue(html.contains("Server not found"))
        XCTAssertTrue(html.contains("https://example.com/path"))
        XCTAssertTrue(html.contains(">Reload</a>"))
        XCTAssertTrue(html.contains(AppInfo.displayName))
    }

    func testFailingURLFromUserInfo() throws {
        let expected = try XCTUnwrap(URL(string: "https://example.com/fail"))
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSURLErrorFailingURLErrorKey: expected]
        )
        XCTAssertEqual(LoadFailureCopy.failingURL(from: error), expected)
    }

    func testSanitizeStripsOverrideAndTruncates() {
        let long = String(repeating: "a", count: 300)
        let copy = LoadFailureCopy.from(urlErrorCode: NSURLErrorUnknown, localized: "\u{202E}" + long)
        XCTAssertFalse(copy.detail.contains("\u{202E}"))
        XCTAssertLessThanOrEqual(copy.detail.count, 280)
        XCTAssertTrue(copy.detail.hasSuffix("…"))
    }
}

final class ServerTrustAllowlistTests: XCTestCase {
    func testAllowlistIsHostAndFingerprintSpecific() {
        let list = ServerTrustAllowlist()
        let a = ServerTrustAllowKey(host: "Example.COM", port: 8443, fingerprintSHA256: "ABCD")
        let b = ServerTrustAllowKey(host: "example.com", port: 8443, fingerprintSHA256: "abcd")
        let otherFP = ServerTrustAllowKey(host: "example.com", port: 8443, fingerprintSHA256: "ffff")
        let otherHost = ServerTrustAllowKey(host: "other.example", port: 8443, fingerprintSHA256: "abcd")
        XCTAssertEqual(a, b)
        XCTAssertFalse(list.contains(a))
        list.allow(a)
        XCTAssertTrue(list.contains(b))
        XCTAssertFalse(list.contains(otherFP))
        XCTAssertFalse(list.contains(otherHost))
        list.removeAll()
        XCTAssertFalse(list.contains(a))
    }

    func testDisplayHostIncludesPort() {
        let key = ServerTrustAllowKey(host: "host.example", port: 8443, fingerprintSHA256: "aa")
        XCTAssertEqual(key.displayHost, "host.example:8443")
        let bare = ServerTrustAllowKey(host: "host.example", fingerprintSHA256: "aa")
        XCTAssertEqual(bare.displayHost, "host.example")
    }

    func testAlertBodyMentionsHost() {
        let info = ServerTrustCertificateInfo(
            subjectSummary: "CN=test",
            issuerSummary: "CN=test",
            fingerprintSHA256: "0123456789abcdef0123456789abcdef"
        )
        let body = info.alertBody(hostDisplay: "lab.example:8443")
        XCTAssertTrue(body.contains("lab.example:8443"))
        XCTAssertTrue(body.contains("Certificate: CN=test"))
        XCTAssertTrue(body.contains("0123456789abcdef"))
        XCTAssertTrue(body.contains(AppInfo.displayName))
    }

#if canImport(CryptoKit)
    func testFingerprintIsLowercaseSHA256() {
        let digest = ServerTrustAllowlist.fingerprintSHA256(of: Data("example".utf8))
        XCTAssertEqual(digest, "50d858e0985ecc7f60418aaf0cc5ab587f42c2570a884095a9e8ccacd0f6545c")
    }
#endif
}
