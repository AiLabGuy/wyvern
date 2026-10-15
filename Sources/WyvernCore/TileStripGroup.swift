// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Strip grouping for a saved split. Members stay a group while the split exists,
/// including while a non-member tab is selected and the split is hidden.
public enum TileStripGroup {
    /// IDs that draw as group members. Empty when there is no saved split.
    public static func memberIDs(savedSplitTabIDs: [UUID], splitExists: Bool) -> Set<UUID> {
        guard splitExists, savedSplitTabIDs.count >= 2 else { return [] }
        return Set(savedSplitTabIDs)
    }

    /// Insert after `afterID`, or at the end when that tab is missing.
    /// If that slot would land inside the saved group, skip to just after the last member.
    public static func insertionIndex(session: [UUID], afterID: UUID?, members: Set<UUID>) -> Int {
        let preferred: Int
        if let afterID, let index = session.firstIndex(of: afterID) {
            preferred = index + 1
        } else {
            preferred = session.count
        }
        return indexSkippingPastGroup(session: session, preferredIndex: preferred, members: members)
    }

    /// Moves `preferredIndex` to after the last group member when it would split the group.
    public static func indexSkippingPastGroup(
        session: [UUID],
        preferredIndex: Int,
        members: Set<UUID>
    ) -> Int {
        let index = min(max(preferredIndex, 0), session.count)
        guard members.count >= 2 else { return index }
        let memberPositions = session.indices.filter { members.contains(session[$0]) }
        guard let first = memberPositions.first, let last = memberPositions.last else {
            return index
        }
        if index > first && index <= last {
            return last + 1
        }
        return index
    }

    /// Strip slots the group capsule covers, from the first member through the last.
    /// Nil when fewer than two members are present, so a single tab never draws a capsule.
    /// The range is inclusive. Callers place members contiguously before asking.
    public static func memberSpan(session: [UUID], members: Set<UUID>) -> ClosedRange<Int>? {
        guard members.count >= 2, !session.isEmpty else { return nil }
        var first: Int?
        var last = 0
        var count = 0
        for index in session.indices where members.contains(session[index]) {
            if first == nil {
                first = index
            }
            last = index
            count += 1
        }
        guard count >= 2, let first else { return nil }
        return first...last
    }
}
