// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Distances are in points. A click shorter than `startDistance` never becomes a drag.
public enum TabDragPolicy {
    public static let startDistance: Double = 4
    public static let detachDistance: Double = 24

    /// Squared travel from mouse-down at or past `startDistance`.
    public static func dragHasStarted(travelSquared: Double) -> Bool {
        travelSquared >= startDistance * startDistance
    }

    /// The source browser window never follows the pointer during a tab gesture.
    /// Only the tab, or a lightweight snapshot of it, moves with the cursor.
    public static func sourceWindowFollowsPointer() -> Bool {
        false
    }

    /// Empty chrome may call `performDrag` only when no tab gesture is capturing the pointer.
    public static func allowsExplicitWindowDrag(tabGestureActive: Bool) -> Bool {
        !tabGestureActive
    }

    /// Moving the whole window is allowed only as the drop of a lone tab into empty space.
    /// A lone tab over another window's strip is a move, not a window slide.
    public static func shouldMoveSourceWindowOnDrop(
        tabCount: Int,
        overForeignStrip: Bool,
        isDetachDrop: Bool
    ) -> Bool {
        tabCount == 1 && isDetachDrop && !overForeignStrip
    }

    public static func action(for query: TabDragDropQuery) -> TabDragDropAction {
        if query.cancelled {
            return .cancel
        }
        if query.pageContainsPoint {
            if query.hasUsableTileTarget {
                return .tile
            }
            if query.hasUnusableTileTarget {
                return .cancel
            }
            if query.verticalDistanceToSourceStrip <= detachDistance {
                return .cancel
            }
        }
        switch query.stripHit {
        case .source(let index):
            return .reorder(visibleIndex: index)
        case .foreign(let index):
            return .moveToForeignStrip(visibleIndex: index)
        case .none:
            break
        }
        let outside = !query.windowContainsPoint
        if outside || query.verticalDistanceToSourceStrip > detachDistance {
            if shouldMoveSourceWindowOnDrop(
                tabCount: query.tabCount,
                overForeignStrip: false,
                isDetachDrop: true
            ) {
                return .moveSourceWindow
            }
            return .detachToNewWindow
        }
        return .reorder(visibleIndex: query.sourceDropIndex)
    }
}

/// Which window's tab strip contains the pointer, already resolved front-to-back.
public enum TabDragStripHit: Equatable, Sendable {
    case none
    case source(visibleIndex: Int)
    case foreign(visibleIndex: Int)
}

public struct TabDragDropQuery: Equatable, Sendable {
    public var cancelled: Bool
    public var pageContainsPoint: Bool
    public var hasUsableTileTarget: Bool
    public var hasUnusableTileTarget: Bool
    public var verticalDistanceToSourceStrip: Double
    public var stripHit: TabDragStripHit
    public var windowContainsPoint: Bool
    public var tabCount: Int
    public var sourceDropIndex: Int

    public init(
        cancelled: Bool,
        pageContainsPoint: Bool,
        hasUsableTileTarget: Bool,
        hasUnusableTileTarget: Bool,
        verticalDistanceToSourceStrip: Double,
        stripHit: TabDragStripHit,
        windowContainsPoint: Bool,
        tabCount: Int,
        sourceDropIndex: Int
    ) {
        self.cancelled = cancelled
        self.pageContainsPoint = pageContainsPoint
        self.hasUsableTileTarget = hasUsableTileTarget
        self.hasUnusableTileTarget = hasUnusableTileTarget
        self.verticalDistanceToSourceStrip = verticalDistanceToSourceStrip
        self.stripHit = stripHit
        self.windowContainsPoint = windowContainsPoint
        self.tabCount = tabCount
        self.sourceDropIndex = sourceDropIndex
    }
}

public enum TabDragDropAction: Equatable, Sendable {
    case cancel
    case tile
    case reorder(visibleIndex: Int)
    case moveToForeignStrip(visibleIndex: Int)
    case detachToNewWindow
    case moveSourceWindow
}
