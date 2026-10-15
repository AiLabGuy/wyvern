// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class HostsListParserTests: XCTestCase {
    func testHostsLinesCommentsAndPlainDomains() {
        let text = """
        # comment
        0.0.0.0 ads.example.com
        127.0.0.1 x
        ::1 tracker.example
        plain.example.org

        \t
        0.0.0.0 one.example two.example # three.example
        0.0.0.0 kept.example#inline
        """
        XCTAssertEqual(
            HostsListParser.parse(text),
            ["ads.example.com", "kept.example", "one.example", "plain.example.org", "tracker.example", "two.example"]
        )
        XCTAssertFalse(HostsListParser.parse(text).contains("x"))
        XCTAssertEqual(HostsListParser.parse("0.0.0.0 com\n! Last modified Oct\n"), [])
        XCTAssertEqual(HostsListParser.parse("example.123\nfoo.99\n"), [])
    }

    func testCRLFUppercaseTrailingDotAndIDNPunycode() {
        let text = "0.0.0.0 ADS.Example.COM.\r\n0.0.0.0 xn--e1afmkfd.xn--p1ai\rMÜNCHEN.example\n*.Wild.Example.net.\n"
        XCTAssertEqual(
            HostsListParser.parse(text),
            ["ads.example.com", "wild.example.net", "xn--e1afmkfd.xn--p1ai", "xn--mnchen-3ya.example"]
        )
        XCTAssertEqual(HostsListParser.canonicalHost("bücher.example"), "xn--bcher-kva.example")
        XCTAssertNil(HostsListParser.canonicalHost("münchen"))
    }

    func testLeadingBOMDoesNotDropTheFirstDomain() {
        let text = "\u{FEFF}ads.example\ntracker.example\n"
        XCTAssertEqual(HostsListParser.parse(text), ["ads.example", "tracker.example"])
        XCTAssertEqual(HostsListParser.listTitle("! Title: Cookie banners\nads.example\n"), "Cookie banners")
        XCTAssertEqual(HostsListParser.listTitle("# Title: Other\n"), "Other")
    }

    func testSkipsLocalNamesIPLiteralsAndInvalidLabels() {
        let text = """
        127.0.0.1 localhost
        127.0.0.1 localhost.localdomain
        127.0.0.1 local
        255.255.255.255 broadcasthost
        ::1 localhost
        2001:db8::1%lo0 localhost
        0.0.0.0 0.0.0.0
        0.0.0.0 203.0.113.9
        1.2.3.4
        ::1
        -bad.example
        bad-.example
        a..b.example
        has_underscore.example
        \(String(repeating: "a", count: 64)).example
        """
        XCTAssertEqual(HostsListParser.parse(text), [])
        XCTAssertEqual(HostsListParser.parse("0.0.0.0 ok.example\n127.0.0.1 localhost"), ["ok.example"])
        XCTAssertNil(HostsListParser.canonicalHost("com"))
        XCTAssertNil(HostsListParser.canonicalHost("oct"))
        XCTAssertNil(HostsListParser.canonicalHost("x"))
        XCTAssertNil(HostsListParser.canonicalHost("example.123"))
        XCTAssertEqual(
            HostsListParser.parse("0.0.0.0 com\n! Last modified Oct\n0.0.0.0 ads.example\n"),
            ["ads.example"]
        )
    }

    func testDedupesAndDropsCoveredSubdomains() {
        let text = """
        example.com
        ads.example.com
        a.b.example.com
        Example.COM
        other.org
        sub.other.org
        notexample.com
        example.com.evil.test
        """
        XCTAssertEqual(
            HostsListParser.parse(text),
            ["example.com", "example.com.evil.test", "notexample.com", "other.org"]
        )
    }

    func testParentCollapseKeepsSiblings() {
        XCTAssertEqual(
            HostsListParser.parse("a.example.com\nb.example.com\n"),
            ["a.example.com", "b.example.com"]
        )
    }

    func testHugeLineIsSkippedAndShortNeighborIsKept() {
        let padding = String(repeating: "a", count: HostsListParser.maxLineScalars + 8)
        let text = "\(padding).example\n0.0.0.0 ads.example\n"
        XCTAssertEqual(HostsListParser.parse(text), ["ads.example"])
        XCTAssertEqual(HostsListParser.parse("\u{FEFF}0.0.0.0 ads.example\n\u{0000}not a host\n"), ["ads.example"])
        XCTAssertNil(HostsListParser.canonicalHost("a\"b.example"))
        XCTAssertNil(HostsListParser.canonicalHost("a|b.example"))
    }

    func testUniqueCeilingRejectsBeforeCollapse() {
        let text = "a.example\nsub.a.example\nb.example\n"
        XCTAssertEqual(HostsListParser.parseOutcome(text, maxUnique: 2), .tooLarge)
        XCTAssertEqual(HostsListParser.parse(text, maxUnique: 2), [])
        if case .domains(let domains) = HostsListParser.parseOutcome(text, maxUnique: 3) {
            XCTAssertEqual(domains, ["a.example", "b.example"])
        } else {
            XCTFail("expected domains")
        }
    }
}
