// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class SiteBadgeTests: XCTestCase {
    func testHostColorIsStableAndInThePalette() {
        let first = SiteBadge.colorHex(forHost: "Docs.Example.ORG")
        let second = SiteBadge.colorHex(forHost: "docs.example.org")
        XCTAssertEqual(first, second)
        XCTAssertTrue(SiteBadge.palette.contains(first))
        XCTAssertTrue(SiteBadge.palette.contains(SiteBadge.colorHex(forHost: "")))
    }

    func testFixedListAndNewTabColors() {
        XCTAssertEqual(SiteBadge.listHex, "#8A9099")
        XCTAssertEqual(SiteBadge.newTabHex, "#8A8A8A")
        XCTAssertEqual(SiteBadge.palette, ["#5B7C99", "#7A8F5B", "#99705B", "#6B6B99", "#8A9099"])
    }

    func testLetterFromTitle() {
        XCTAssertEqual(SiteBadge.letter(forTitle: " encyclopedia"), "E")
        XCTAssertEqual(SiteBadge.letter(forTitle: "123"), "1")
        XCTAssertEqual(SiteBadge.letter(forTitle: ""), "?")
        XCTAssertEqual(SiteBadge.letter(forTitle: "  "), "?")
        XCTAssertEqual(SiteBadge.letter(forTitle: "—notes"), "?")
    }
}
