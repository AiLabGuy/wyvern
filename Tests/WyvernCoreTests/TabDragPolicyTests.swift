// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class TabDragPolicyTests: XCTestCase {
    func testStartDistanceIgnoresAShortClick() {
        XCTAssertFalse(TabDragPolicy.dragHasStarted(travelSquared: 0))
        XCTAssertFalse(TabDragPolicy.dragHasStarted(travelSquared: 15))
        XCTAssertTrue(TabDragPolicy.dragHasStarted(travelSquared: 16))
        XCTAssertTrue(TabDragPolicy.dragHasStarted(travelSquared: 100))
    }

    func testSourceWindowNeverFollowsThePointer() {
        XCTAssertFalse(TabDragPolicy.sourceWindowFollowsPointer())
    }

    func testExplicitWindowDragIsBlockedDuringATabGesture() {
        XCTAssertTrue(TabDragPolicy.allowsExplicitWindowDrag(tabGestureActive: false))
        XCTAssertFalse(TabDragPolicy.allowsExplicitWindowDrag(tabGestureActive: true))
    }

    func testLastTabMovesTheWindowOnlyForAnEmptySpaceDetach() {
        XCTAssertTrue(
            TabDragPolicy.shouldMoveSourceWindowOnDrop(
                tabCount: 1,
                overForeignStrip: false,
                isDetachDrop: true
            )
        )
        XCTAssertFalse(
            TabDragPolicy.shouldMoveSourceWindowOnDrop(
                tabCount: 1,
                overForeignStrip: true,
                isDetachDrop: true
            )
        )
        XCTAssertFalse(
            TabDragPolicy.shouldMoveSourceWindowOnDrop(
                tabCount: 2,
                overForeignStrip: false,
                isDetachDrop: true
            )
        )
        XCTAssertFalse(
            TabDragPolicy.shouldMoveSourceWindowOnDrop(
                tabCount: 1,
                overForeignStrip: false,
                isDetachDrop: false
            )
        )
    }

    func testEscapeCancels() {
        XCTAssertEqual(TabDragPolicy.action(for: query(cancelled: true, tabCount: 2)), .cancel)
        XCTAssertEqual(TabDragPolicy.action(for: query(cancelled: true, tabCount: 1)), .cancel)
    }

    func testUsableTileDropTiles() {
        var q = query(pageContainsPoint: true, hasUsableTileTarget: true, tabCount: 3)
        XCTAssertEqual(TabDragPolicy.action(for: q), .tile)
        q.tabCount = 1
        XCTAssertEqual(TabDragPolicy.action(for: q), .tile)
    }

    func testUnusableTileDropCancelsInsteadOfDetaching() {
        let q = query(
            pageContainsPoint: true,
            hasUnusableTileTarget: true,
            verticalDistanceToSourceStrip: 80,
            tabCount: 3
        )
        XCTAssertEqual(TabDragPolicy.action(for: q), .cancel)
    }

    func testNearStripOnThePageCancels() {
        let q = query(
            pageContainsPoint: true,
            verticalDistanceToSourceStrip: 24,
            tabCount: 3
        )
        XCTAssertEqual(TabDragPolicy.action(for: q), .cancel)
    }

    func testReorderOnTheSourceStrip() {
        let q = query(stripHit: .source(visibleIndex: 2), tabCount: 4, sourceDropIndex: 2)
        XCTAssertEqual(TabDragPolicy.action(for: q), .reorder(visibleIndex: 2))
    }

    func testDropOnAForeignStripMovesTheTab() {
        var q = query(
            stripHit: .foreign(visibleIndex: 1),
            windowContainsPoint: false,
            tabCount: 3,
            sourceDropIndex: 0
        )
        XCTAssertEqual(TabDragPolicy.action(for: q), .moveToForeignStrip(visibleIndex: 1))
        q.tabCount = 1
        XCTAssertEqual(TabDragPolicy.action(for: q), .moveToForeignStrip(visibleIndex: 1))
    }

    func testForeignStripWinsOverLastTabWindowMove() {
        let q = query(
            stripHit: .foreign(visibleIndex: 0),
            windowContainsPoint: false,
            tabCount: 1
        )
        XCTAssertEqual(TabDragPolicy.action(for: q), .moveToForeignStrip(visibleIndex: 0))
        XCTAssertFalse(
            TabDragPolicy.shouldMoveSourceWindowOnDrop(
                tabCount: 1,
                overForeignStrip: true,
                isDetachDrop: true
            )
        )
    }

    func testEmptySpaceWithSeveralTabsDetaches() {
        let q = query(
            verticalDistanceToSourceStrip: 80,
            windowContainsPoint: false,
            tabCount: 3
        )
        XCTAssertEqual(TabDragPolicy.action(for: q), .detachToNewWindow)
    }

    func testEmptySpaceWithTheLastTabMovesTheWindow() {
        let q = query(
            verticalDistanceToSourceStrip: 80,
            windowContainsPoint: false,
            tabCount: 1
        )
        XCTAssertEqual(TabDragPolicy.action(for: q), .moveSourceWindow)
    }

    func testFarPageDropDetachesWhenSeveralTabsRemain() {
        let q = query(
            pageContainsPoint: true,
            verticalDistanceToSourceStrip: 80,
            windowContainsPoint: true,
            tabCount: 2
        )
        XCTAssertEqual(TabDragPolicy.action(for: q), .detachToNewWindow)
    }

    func testFarPageDropMovesALoneWindow() {
        let q = query(
            pageContainsPoint: true,
            verticalDistanceToSourceStrip: 80,
            windowContainsPoint: true,
            tabCount: 1
        )
        XCTAssertEqual(TabDragPolicy.action(for: q), .moveSourceWindow)
    }

    func testNearStripOutsideThePageReorders() {
        let q = query(
            verticalDistanceToSourceStrip: 10,
            windowContainsPoint: true,
            tabCount: 3,
            sourceDropIndex: 1
        )
        XCTAssertEqual(TabDragPolicy.action(for: q), .reorder(visibleIndex: 1))
    }

    private func query(
        cancelled: Bool = false,
        pageContainsPoint: Bool = false,
        hasUsableTileTarget: Bool = false,
        hasUnusableTileTarget: Bool = false,
        verticalDistanceToSourceStrip: Double = 0,
        stripHit: TabDragStripHit = .none,
        windowContainsPoint: Bool = true,
        tabCount: Int,
        sourceDropIndex: Int = 0
    ) -> TabDragDropQuery {
        TabDragDropQuery(
            cancelled: cancelled,
            pageContainsPoint: pageContainsPoint,
            hasUsableTileTarget: hasUsableTileTarget,
            hasUnusableTileTarget: hasUnusableTileTarget,
            verticalDistanceToSourceStrip: verticalDistanceToSourceStrip,
            stripHit: stripHit,
            windowContainsPoint: windowContainsPoint,
            tabCount: tabCount,
            sourceDropIndex: sourceDropIndex
        )
    }
}
