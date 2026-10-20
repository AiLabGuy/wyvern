// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class AddressTypographyTests: XCTestCase {
    func testEditingAndCommittedTextShareOneSpec() {
        let committed = AddressTypography.spec(for: .committedURL)
        for state in AddressTypography.State.allCases {
            XCTAssertEqual(AddressTypography.spec(for: state), committed, "\(state) must match the committed URL font")
        }
    }

    func testNewTabTypingUsesTheCommittedFont() {
        XCTAssertEqual(AddressTypography.spec(for: .editingEmpty), AddressTypography.spec(for: .committedURL))
    }

    func testAddressTextIsRegularMonospacedTwelvePoint() {
        XCTAssertEqual(AddressTypography.text.design, .monospaced)
        XCTAssertEqual(AddressTypography.text.size, 12)
        XCTAssertEqual(AddressTypography.text.weight, 0)
    }
}
