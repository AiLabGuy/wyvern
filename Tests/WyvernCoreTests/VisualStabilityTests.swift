// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class VisualStabilityTests: XCTestCase {
    func testAlreadyHostedViewIsNotMoved() {
        XCTAssertFalse(HostedViewPlacement.shouldMove(isChildOfTarget: true))
        XCTAssertTrue(HostedViewPlacement.shouldMove(isChildOfTarget: false))
    }

    func testRaiseSkipsAViewThatIsAlreadyInFront() {
        XCTAssertFalse(HostedViewPlacement.shouldRaise(isChildOfTarget: true, isFrontmost: true))
        XCTAssertTrue(HostedViewPlacement.shouldRaise(isChildOfTarget: true, isFrontmost: false))
        XCTAssertTrue(HostedViewPlacement.shouldRaise(isChildOfTarget: false, isFrontmost: false))
        XCTAssertTrue(HostedViewPlacement.shouldRaise(isChildOfTarget: false, isFrontmost: true))
    }

    func testLayoutNotifyCollapsesUntilTaken() {
        var gate = LayoutNotifyCoalescer()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.pending)
        XCTAssertTrue(gate.take())
        XCTAssertFalse(gate.pending)
        XCTAssertFalse(gate.take())
        XCTAssertTrue(gate.request())
    }
}
