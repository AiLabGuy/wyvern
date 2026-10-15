// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class TileStripGroupTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let d = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

    func testSavedSplitMembersStayGroupedWhenSplitIsHidden() {
        let ids = TileStripGroup.memberIDs(savedSplitTabIDs: [a, b], splitExists: true)
        XCTAssertEqual(ids, [a, b])
        XCTAssertTrue(TileStripGroup.memberIDs(savedSplitTabIDs: [a, b], splitExists: false).isEmpty)
        XCTAssertTrue(TileStripGroup.memberIDs(savedSplitTabIDs: [a], splitExists: true).isEmpty)
        XCTAssertTrue(TileStripGroup.memberIDs(savedSplitTabIDs: [], splitExists: true).isEmpty)
    }

    func testNewTabAfterAMemberSkipsPastTheGroup() {
        let members: Set<UUID> = [a, b]
        // [A, B] with A selected would otherwise insert between them.
        XCTAssertEqual(
            TileStripGroup.insertionIndex(session: [a, b], afterID: a, members: members),
            2
        )
        // Already after the last member.
        XCTAssertEqual(
            TileStripGroup.insertionIndex(session: [a, b], afterID: b, members: members),
            2
        )
        // Group in the middle, new tab from a non-member stays after that tab.
        XCTAssertEqual(
            TileStripGroup.insertionIndex(session: [a, b, c], afterID: c, members: members),
            3
        )
        // Group then a later tab; inserting after A must land after B, not between A and B.
        XCTAssertEqual(
            TileStripGroup.insertionIndex(session: [a, b, c], afterID: a, members: members),
            2
        )
    }

    func testInsertionDoesNotSplitAGroupEvenWhenMembersAreNotAdjacent() {
        let members: Set<UUID> = [a, b]
        XCTAssertEqual(
            TileStripGroup.insertionIndex(session: [a, c, b], afterID: a, members: members),
            3
        )
        XCTAssertEqual(
            TileStripGroup.indexSkippingPastGroup(session: [a, c, b], preferredIndex: 1, members: members),
            3
        )
        XCTAssertEqual(
            TileStripGroup.indexSkippingPastGroup(session: [a, c, b], preferredIndex: 0, members: members),
            0
        )
        XCTAssertEqual(
            TileStripGroup.indexSkippingPastGroup(session: [a, b, c], preferredIndex: 3, members: members),
            3
        )
    }

    func testCapsuleSpanMatchesReadingOrderAfterSplitAndUnsplit() {
        // Split the second of two. The new tab is focused and is the right pane.
        let fromSecond = TileStripOrder.placingMembers(session: [a, b, c], focused: c, membersInOrder: [b, c])
        XCTAssertEqual(fromSecond, [a, b, c])
        XCTAssertEqual(TileStripGroup.memberSpan(session: fromSecond, members: [b, c]), 1...2)

        // Split the first of three. The new tab was inserted after the anchor before alignment.
        let fromFirst = TileStripOrder.placingMembers(session: [a, d, b, c], focused: d, membersInOrder: [a, d])
        XCTAssertEqual(fromFirst, [a, d, b, c])
        XCTAssertEqual(TileStripGroup.memberSpan(session: fromFirst, members: [a, d]), 0...1)

        // Unsplit repairs a focused-first strip and then the capsule has no members.
        let unsplit = TileStripOrder.placingMembers(session: [a, c, b], focused: c, membersInOrder: [b, c])
        XCTAssertEqual(unsplit, [a, b, c])
        XCTAssertNil(TileStripGroup.memberSpan(session: unsplit, members: []))
        XCTAssertNil(TileStripGroup.memberSpan(session: [a, b], members: [a]))
        XCTAssertNil(TileStripGroup.memberSpan(session: [], members: [a, b]))
    }

    func testInsertionWithoutAGroupFollowsThePreferredSlot() {
        XCTAssertEqual(
            TileStripGroup.insertionIndex(session: [a, b], afterID: a, members: []),
            1
        )
        XCTAssertEqual(
            TileStripGroup.insertionIndex(session: [a, b], afterID: nil, members: [a, b]),
            2
        )
        XCTAssertEqual(
            TileStripGroup.insertionIndex(session: [a, b], afterID: d, members: [a, b]),
            2
        )
        XCTAssertEqual(
            TileStripGroup.insertionIndex(session: [], afterID: nil, members: []),
            0
        )
    }
}
