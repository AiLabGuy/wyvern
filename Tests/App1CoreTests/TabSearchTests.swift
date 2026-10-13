// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import App1Core

final class TabSearchTests: XCTestCase {
    private let web = TabSearchEntry(
        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        title: "Example Domain",
        url: "https://example.com/docs",
        kind: .web
    )
    private let other = TabSearchEntry(
        id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        title: "News",
        url: "https://news.example.org/",
        kind: .web
    )
    private let terminal = TabSearchEntry(
        id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
        title: "Build logs",
        url: "tail -f /var/log/build.log",
        kind: .terminal
    )

    func testEmptyQueryReturnsEveryTabInOrder() {
        let entries = [web, terminal, other]
        XCTAssertEqual(TabSearch.filter(entries, query: ""), entries)
        XCTAssertEqual(TabSearch.filter(entries, query: "   \n"), entries)
    }

    func testCaseInsensitiveSubstringOnTitleAndURL() {
        let entries = [web, other, terminal]
        XCTAssertEqual(TabSearch.filter(entries, query: "EXAMPLE"), [web, other])
        XCTAssertEqual(TabSearch.filter(entries, query: "docs"), [web])
        XCTAssertEqual(TabSearch.filter(entries, query: "NEWS"), [other])
        XCTAssertEqual(TabSearch.filter(entries, query: "nope"), [])
    }

    func testTerminalTabsMatchTitleOrCommand() {
        let entries = [web, terminal]
        XCTAssertEqual(TabSearch.filter(entries, query: "build"), [terminal])
        XCTAssertEqual(TabSearch.filter(entries, query: "TAIL"), [terminal])
        XCTAssertEqual(TabSearch.filter(entries, query: "log"), [terminal])
        XCTAssertEqual(terminal.kind, .terminal)
    }

    func testMatchIsSubstringNotPrefixAndKeepsOrder() {
        let entries = [other, web, terminal]
        let matched = TabSearch.filter(entries, query: "example")
        XCTAssertEqual(matched.map(\.id), [other.id, web.id])
    }
}
