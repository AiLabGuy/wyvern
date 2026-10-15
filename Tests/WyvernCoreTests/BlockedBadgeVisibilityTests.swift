// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class BlockedBadgeVisibilityTests: XCTestCase {
    func testShowsOnHTTPWebPagesWhenCountToggleOrBlockingIsOn() {
        XCTAssertTrue(
            BlockedBadgeVisibility.shouldShow(
                blockingEnabled: false,
                showBlockedCount: true,
                isTerminal: false,
                isWebSurface: true,
                scheme: "https"
            )
        )
        XCTAssertTrue(
            BlockedBadgeVisibility.shouldShow(
                blockingEnabled: true,
                showBlockedCount: false,
                isTerminal: false,
                isWebSurface: true,
                scheme: "HTTP"
            )
        )
        XCTAssertFalse(
            BlockedBadgeVisibility.shouldShow(
                blockingEnabled: false,
                showBlockedCount: false,
                isTerminal: false,
                isWebSurface: true,
                scheme: "https"
            )
        )
    }

    func testHidesOffWebHTTPSurfaces() {
        XCTAssertFalse(
            BlockedBadgeVisibility.shouldShow(
                blockingEnabled: true,
                showBlockedCount: true,
                isTerminal: true,
                isWebSurface: true,
                scheme: "https"
            )
        )
        XCTAssertFalse(
            BlockedBadgeVisibility.shouldShow(
                blockingEnabled: true,
                showBlockedCount: true,
                isTerminal: false,
                isWebSurface: false,
                scheme: "https"
            )
        )
        XCTAssertFalse(
            BlockedBadgeVisibility.shouldShow(
                blockingEnabled: true,
                showBlockedCount: true,
                isTerminal: false,
                isWebSurface: true,
                scheme: "file"
            )
        )
        XCTAssertFalse(
            BlockedBadgeVisibility.shouldShow(
                blockingEnabled: true,
                showBlockedCount: true,
                isTerminal: false,
                isWebSurface: true,
                scheme: nil
            )
        )
    }

    func testConstraintWidthIsNonzeroBeforeUnhiding() {
        XCTAssertEqual(BlockedBadgeVisibility.constraintWidth(visible: false, preferredWidth: 24), 0)
        XCTAssertEqual(BlockedBadgeVisibility.constraintWidth(visible: true, preferredWidth: 24), 24)
        XCTAssertEqual(BlockedBadgeVisibility.constraintWidth(visible: true, preferredWidth: 48), 48)
        XCTAssertEqual(BlockedBadgeVisibility.constraintWidth(visible: true, preferredWidth: -4), 0)
    }
}
