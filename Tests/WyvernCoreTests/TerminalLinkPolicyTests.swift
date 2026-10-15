// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class TerminalLinkPolicyTests: XCTestCase {
    func testWebLinksAreAllowed() {
        XCTAssertTrue(TerminalLinkPolicy.allows("https://example.invalid/a"))
        XCTAssertTrue(TerminalLinkPolicy.allows(" http://example.invalid "))
    }

    func testOtherSchemesAreDropped() {
        XCTAssertFalse(TerminalLinkPolicy.allows("javascript:alert(1)"))
        XCTAssertFalse(TerminalLinkPolicy.allows("file:///etc/passwd"))
        XCTAssertFalse(TerminalLinkPolicy.allows("data:text/html,hi"))
        XCTAssertFalse(TerminalLinkPolicy.allows("https://user:pass@example.invalid/"))
        XCTAssertFalse(TerminalLinkPolicy.allows("https://"))
        XCTAssertFalse(TerminalLinkPolicy.allows(""))
    }
}
