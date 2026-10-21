// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class IconTileLayoutTests: XCTestCase {
    private let label = CGSize(width: 48, height: 14)

    func testIntrinsicSizeFitsTheFullIconAndLabel() {
        let size = IconTileLayout.size(labelHeight: label.height)
        XCTAssertGreaterThanOrEqual(size.height, IconTileLayout.maxSide + label.height)
        XCTAssertLessThanOrEqual(size.height, 96, "fits the approved 96 pt row")
        XCTAssertGreaterThanOrEqual(size.width, IconTileLayout.maxSide)
    }

    func testIconIsFullSizeAndInsideTheTileAtTheIntrinsicSize() {
        let bounds = IconTileLayout.size(labelHeight: label.height)
        let frames = IconTileLayout.frames(in: bounds, labelSize: label)
        XCTAssertEqual(frames.thumb.width, 64)
        XCTAssertEqual(frames.thumb.height, 64)
        assertInside(frames.thumb, bounds)
        assertInside(frames.label, bounds)
        XCTAssertGreaterThan(frames.label.minY, frames.thumb.maxY, "label sits below the icon")
    }

    func testWideRowTileKeepsTheIconInBounds() {
        // A fillEqually row of four in the default Settings width, 96 pt tall.
        let bounds = CGSize(width: 130, height: 96)
        let frames = IconTileLayout.frames(in: bounds, labelSize: label)
        XCTAssertEqual(frames.thumb.width, 64)
        assertInside(frames.thumb, bounds)
        XCTAssertEqual(frames.thumb.midX, bounds.width / 2, accuracy: 0.5)
    }

    func testNarrowTileShrinksTheIconInsteadOfClipping() {
        let bounds = CGSize(width: 50, height: 96)
        let frames = IconTileLayout.frames(in: bounds, labelSize: label)
        XCTAssertEqual(frames.thumb.width, 42)
        XCTAssertGreaterThanOrEqual(frames.thumb.width, IconTileLayout.minSide)
        assertInside(frames.thumb, bounds)
    }

    func testTheOldTextButtonHeightIsWhatClippedTheIcon() {
        // b211: the tile was only as tall as its title. The icon cannot fit there,
        // which is why the intrinsic size must include the icon.
        let squashed = CGSize(width: 130, height: 20)
        XCTAssertEqual(IconTileLayout.side(in: squashed, labelHeight: label.height), 0)
        XCTAssertGreaterThan(IconTileLayout.size(labelHeight: label.height).height, squashed.height * 4)
    }

    private func assertInside(_ rect: CGRect, _ bounds: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(CGRect(origin: .zero, size: bounds).contains(rect), "\(rect) outside \(bounds)", file: file, line: line)
    }
}
