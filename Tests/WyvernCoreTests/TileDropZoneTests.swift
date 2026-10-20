// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class TileDropZoneTests: XCTestCase {
    func testCenterIsTheInnerHalf() {
        XCTAssertEqual(TileDropClassifier.edgeFraction, 0.25, accuracy: 1e-12)
        XCTAssertEqual(TileDropClassifier.centerFraction, 0.5, accuracy: 1e-12)
        XCTAssertEqual(TileDropClassifier.zone(x: 0.5, y: 0.5, allowTop: false), .center)
        XCTAssertEqual(TileDropClassifier.zone(x: 0.26, y: 0.26, allowTop: false), .center)
        XCTAssertEqual(TileDropClassifier.zone(x: 0.74, y: 0.74, allowTop: false), .center)
        // Top band is interior when the top edge is not a drop target.
        XCTAssertEqual(TileDropClassifier.zone(x: 0.5, y: 0.9, allowTop: false), .center)
    }

    func testEdgeBandsMatchTheExistingTwentyFivePercent() {
        XCTAssertEqual(TileDropClassifier.zone(x: 0.1, y: 0.5, allowTop: false), .edge(.left))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.0, y: 0.5, allowTop: false), .edge(.left))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.25, y: 0.5, allowTop: false), .edge(.left))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.9, y: 0.5, allowTop: false), .edge(.right))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.75, y: 0.5, allowTop: false), .edge(.right))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.5, y: 0.1, allowTop: false), .edge(.down))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.5, y: 0.25, allowTop: false), .edge(.down))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.5, y: 0.26, allowTop: false), .center)
        XCTAssertEqual(TileDropClassifier.zone(x: 0.5, y: 0.9, allowTop: true), .edge(.up))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.5, y: 0.75, allowTop: true), .edge(.up))
    }

    func testLeftAndRightWinOverVerticalEdges() {
        XCTAssertEqual(TileDropClassifier.zone(x: 0.1, y: 0.1, allowTop: false), .edge(.left))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.9, y: 0.1, allowTop: false), .edge(.right))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.1, y: 0.9, allowTop: true), .edge(.left))
        XCTAssertEqual(TileDropClassifier.zone(x: 0.9, y: 0.9, allowTop: true), .edge(.right))
    }

    func testNonFiniteCoordinatesAreIgnored() {
        XCTAssertNil(TileDropClassifier.zone(x: .nan, y: 0.5, allowTop: false))
        XCTAssertNil(TileDropClassifier.zone(x: 0.5, y: .infinity, allowTop: false))
    }
}
