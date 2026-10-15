// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The five split layouts a window may show. One window holds one of these, and nothing else.
///
/// Trees:
/// - twoColumns: horizontal `[a, b]`
/// - twoRows: vertical `[a, b]` with `a` on top
/// - threeColumns: horizontal `[a, b, c]`
/// - onePlusTwo: horizontal `[a, vertical[b, c]]` — big pane on the left
/// - grid: vertical `[horizontal[a, b], horizontal[c, d]]` — row-major
public enum TileArrangement: String, Codable, Equatable, Sendable, CaseIterable {
    case twoColumns
    case twoRows
    case threeColumns
    case grid
    case onePlusTwo

    public static let minimumPanes = 2
    public static let maximumPanes = 4

    public var paneCount: Int {
        switch self {
        case .twoColumns, .twoRows:
            return 2
        case .threeColumns, .onePlusTwo:
            return 3
        case .grid:
            return 4
        }
    }

    public var accessibilityName: String {
        switch self {
        case .twoColumns: return "2 columns"
        case .twoRows: return "2 rows"
        case .threeColumns: return "3 columns"
        case .grid: return "2 by 2 grid"
        case .onePlusTwo: return "1 plus 2"
        }
    }

    /// Mini glyph the tab strip draws for a member of this layout.
    public var stripGlyph: TileStripGlyph {
        switch self {
        case .twoColumns, .twoRows, .onePlusTwo:
            return .twoColumns
        case .threeColumns:
            return .threeColumns
        case .grid:
            return .grid
        }
    }
}

/// Which split mark a grouped tab draws. The AppKit side maps these to stroke glyphs.
public enum TileStripGlyph: String, Equatable, Sendable {
    case twoColumns
    case threeColumns
    case grid
}

/// Direction from one pane to another. Left and right also drive the swap shortcut.
public enum TileEdge: String, Codable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

/// One pane's slot in a unit square. `y` grows downward, matching reading order.
public struct TilePaneFrame: Equatable, Sendable {
    public var tabID: UUID
    public var kind: TabKind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// Where tiled tabs sit in the strip after a membership change or an unsplit.
public enum TileStripOrder {
    /// Members stay in tile reading order (`membersInOrder`: left to right, then top to bottom).
    /// The group is inserted where its first member already sat. Tabs outside the split keep
    /// their relative order. `focused` is not pulled in front of the earlier panes: doing that
    /// reversed a left-to-right split in the strip.
    public static func placingMembers(session: [UUID], focused _: UUID, membersInOrder: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for id in membersInOrder where seen.insert(id).inserted && session.contains(id) {
            ordered.append(id)
        }
        guard ordered.count >= 2, let anchor = ordered.first, let anchorIndex = session.firstIndex(of: anchor) else {
            return session
        }
        let memberSet = Set(ordered)
        var others: [UUID] = []
        var insertAt = 0
        var passedAnchor = false
        for (index, id) in session.enumerated() {
            if index == anchorIndex {
                passedAnchor = true
            }
            if memberSet.contains(id) {
                continue
            }
            if !passedAnchor {
                insertAt += 1
            }
            others.append(id)
        }
        var result = others
        result.insert(contentsOf: ordered, at: min(insertAt, result.count))
        return result
    }
}

/// Responsive layout. Narrow windows stack columns into full-width rows.
public enum TileDisplay {
    public static func columnCount(in node: TileNode) -> Int {
        switch node {
        case .pane:
            return 1
        case .split(let split):
            if split.axis == .vertical {
                return split.children.map { columnCount(in: $0) }.max() ?? 1
            }
            return split.children.reduce(0) { $0 + columnCount(in: $1) }
        }
    }

    /// True when the columns cannot each keep `paneMinWidth`. The canvas then draws one column of rows.
    public static func needsRowFallback(
        node: TileNode,
        contentWidth: Double,
        paneMinWidth: Double = TileLayout.minimumPaneWidth,
        divider: Double = 8
    ) -> Bool {
        let columns = columnCount(in: node)
        guard columns > 1 else { return false }
        let needed = Double(columns) * paneMinWidth + Double(max(columns - 1, 0)) * divider
        return contentWidth + 0.5 < needed
    }

    /// Window content width when even a single column of `paneMinWidth` does not fit: every pane side by side.
    public static func minimumContentWidth(
        paneCount: Int,
        paneMinWidth: Double = TileLayout.minimumPaneWidth,
        divider: Double = 8
    ) -> Double {
        guard paneCount > 0 else { return 0 }
        return Double(paneCount) * paneMinWidth + Double(max(paneCount - 1, 0)) * divider
    }

    /// Content minimum while a split is showing.
    /// Side-by-side panes can exceed `base`: four panes of 320 plus the gaps is 1304.
    /// A hidden split, or fewer than two panes, stays at `base`. Callers apply this only when it changes.
    public static func requiredContentMinWidth(
        paneCount: Int,
        splitVisible: Bool,
        base: Double = 980,
        paneMinWidth: Double = TileLayout.minimumPaneWidth,
        divider: Double = 8
    ) -> Double {
        guard splitVisible, paneCount > 1 else { return base }
        let needed = minimumContentWidth(
            paneCount: paneCount,
            paneMinWidth: paneMinWidth,
            divider: divider
        )
        return max(base, needed)
    }
}

extension TileArrangement {
    /// Recognizes a canonical tree. Ratios and split ids are ignored. Anything else is nil.
    public static func matching(_ node: TileNode) -> TileArrangement? {
        guard case .split(let split) = node else { return nil }
        if split.axis == .horizontal, split.children.count == 2, split.children.allSatisfy(isPane) {
            return .twoColumns
        }
        if split.axis == .vertical, split.children.count == 2, split.children.allSatisfy(isPane) {
            return .twoRows
        }
        if split.axis == .horizontal, split.children.count == 3, split.children.allSatisfy(isPane) {
            return .threeColumns
        }
        if split.axis == .horizontal,
           split.children.count == 2,
           isPane(split.children[0]),
           let right = asSplit(split.children[1]),
           right.axis == .vertical,
           right.children.count == 2,
           right.children.allSatisfy(isPane) {
            return .onePlusTwo
        }
        if split.axis == .vertical,
           split.children.count == 2,
           let top = asSplit(split.children[0]),
           let bottom = asSplit(split.children[1]),
           top.axis == .horizontal,
           bottom.axis == .horizontal,
           top.children.count == 2,
           bottom.children.count == 2,
           top.children.allSatisfy(isPane),
           bottom.children.allSatisfy(isPane) {
            return .grid
        }
        return nil
    }

    private static func isPane(_ node: TileNode) -> Bool {
        if case .pane = node { return true }
        return false
    }

    private static func asSplit(_ node: TileNode) -> TileSplit? {
        if case .split(let split) = node { return split }
        return nil
    }
}

extension TileLayout {
    public var arrangement: TileArrangement? {
        TileArrangement.matching(root)
    }

    /// Builds one of the five layouts. `tabs` is reading order. Extra ids are ignored.
    /// Returns nil when there are not enough distinct tabs.
    public static func arranged(
        _ arrangement: TileArrangement,
        tabs: [UUID],
        kinds: [TabKind] = [],
        focused: UUID? = nil
    ) -> TileLayout? {
        let count = arrangement.paneCount
        guard tabs.count >= count else { return nil }
        let used = Array(tabs.prefix(count))
        guard Set(used).count == used.count else { return nil }
        func pane(at index: Int) -> TileNode {
            let kind = kinds.indices.contains(index) ? kinds[index] : .web
            return .pane(TilePane(tabID: used[index], kind: kind))
        }
        func even(_ children: [TileNode], axis: TileAxis) -> TileNode {
            let share = 1 / Double(children.count)
            return .split(TileSplit(
                id: UUID(),
                axis: axis,
                children: children,
                ratios: Array(repeating: share, count: children.count)
            ))
        }
        let root: TileNode
        switch arrangement {
        case .twoColumns:
            root = even([pane(at: 0), pane(at: 1)], axis: .horizontal)
        case .twoRows:
            root = even([pane(at: 0), pane(at: 1)], axis: .vertical)
        case .threeColumns:
            root = even([pane(at: 0), pane(at: 1), pane(at: 2)], axis: .horizontal)
        case .onePlusTwo:
            root = even([pane(at: 0), even([pane(at: 1), pane(at: 2)], axis: .vertical)], axis: .horizontal)
        case .grid:
            let top = even([pane(at: 0), pane(at: 1)], axis: .horizontal)
            let bottom = even([pane(at: 2), pane(at: 3)], axis: .horizontal)
            root = even([top, bottom], axis: .vertical)
        }
        let focus = focused.flatMap { used.contains($0) ? $0 : nil } ?? used[0]
        return TileLayout(root: root, focusedTabID: focus)
    }

    /// Snaps a freeform tree onto the arrangement with the same pane count.
    /// A tree that is already canonical is returned unchanged, ratios included.
    public func canonicalized() -> TileLayout {
        if arrangement != nil {
            return self
        }
        let ids = tabIDs()
        let kinds = panes().map(\.kind)
        let focus = ids.contains(focusedTabID) ? focusedTabID : ids.first
        switch ids.count {
        case 2:
            let target: TileArrangement
            if case .split(let split) = root, split.axis == .vertical {
                target = .twoRows
            } else {
                target = .twoColumns
            }
            return TileLayout.arranged(target, tabs: ids, kinds: kinds, focused: focus) ?? self
        case 3:
            return TileLayout.arranged(.threeColumns, tabs: ids, kinds: kinds, focused: focus) ?? self
        case 4:
            return TileLayout.arranged(.grid, tabs: ids, kinds: kinds, focused: focus) ?? self
        default:
            return self
        }
    }

    /// Adds `newID` and lands on the next canonical layout. Nil at 4 panes, or when `anchor` is absent.
    ///
    /// Right from 2 panes becomes 3 columns. Below the second pane becomes 1+2.
    /// Below or above the leading pane is refused: 1+2 cannot divide that pane, and the new
    /// tab would land under the other column. Either direction from 3 panes becomes the grid.
    /// The grid does not grow.
    public func expanded(adding newID: UUID, beside anchor: UUID, edge: TileEdge, kind: TabKind = .web) -> TileLayout? {
        guard newID != anchor, !contains(newID), contains(anchor) else { return nil }
        guard tabIDs().count < TileArrangement.maximumPanes else { return nil }
        let base = arrangement == nil ? canonicalized() : self
        guard let current = base.arrangement else { return nil }
        let target: TileArrangement
        switch (edge, base.tabIDs().count) {
        case (.left, 2), (.right, 2):
            target = .threeColumns
        case (.up, 2), (.down, 2):
            target = .onePlusTwo
        case (_, 3):
            target = .grid
        default:
            return nil
        }
        _ = current
        let order = base.growthOrder(adding: newID, beside: anchor, edge: edge, target: target)
        guard order.count >= target.paneCount else { return nil }
        var kindByID = Dictionary(uniqueKeysWithValues: base.panes().map { ($0.tabID, $0.kind) })
        kindByID[newID] = kind
        let used = Array(order.prefix(target.paneCount))
        let kinds = used.map { kindByID[$0] ?? .web }
        return TileLayout.arranged(target, tabs: used, kinds: kinds, focused: newID)
    }

    /// The next layout when the user picks one from the menu.
    /// Fewer slots keep a window that contains the focused tab.
    /// More slots use `filling` (new tabs) after the current reading order.
    public func converted(to arrangement: TileArrangement, filling: [UUID] = []) -> TileLayout? {
        var order = tabIDs()
        if let focusIndex = order.firstIndex(of: focusedTabID), arrangement.paneCount < order.count {
            let paneCount = arrangement.paneCount
            let start = min(focusIndex, order.count - paneCount)
            order = Array(order[start..<(start + paneCount)])
        }
        for id in filling where !order.contains(id) {
            order.append(id)
        }
        guard order.count >= arrangement.paneCount else { return nil }
        let used = Array(order.prefix(arrangement.paneCount))
        let kindByID = Dictionary(uniqueKeysWithValues: panes().map { ($0.tabID, $0.kind) })
        let kinds = used.map { kindByID[$0] ?? .web }
        let focus = used.contains(focusedTabID) ? focusedTabID : used[0]
        return TileLayout.arranged(arrangement, tabs: used, kinds: kinds, focused: focus)
    }

    /// Full-width rows in reading order. Display-only when the window is narrower than the columns.
    public func stackedDisplay(splitID: UUID) -> TileLayout {
        let records = panes()
        guard records.count >= 2 else { return self }
        let children = records.map { TileNode.pane($0) }
        let share = 1 / Double(children.count)
        return TileLayout(
            root: .split(TileSplit(
                id: splitID,
                axis: .vertical,
                children: children,
                ratios: Array(repeating: share, count: children.count)
            )),
            focusedTabID: focusedTabID
        )
    }

    public func paneFrames() -> [TilePaneFrame] {
        var frames: [TilePaneFrame] = []
        Self.collectFrames(root, x: 0, y: 0, width: 1, height: 1, into: &frames)
        return frames
    }

    /// The pane in `edge`'s direction, preferring the closest slot and then the one nearer the top.
    public func neighbor(of tabID: UUID, toward edge: TileEdge) -> UUID? {
        let frames = paneFrames()
        guard let source = frames.first(where: { $0.tabID == tabID }) else { return nil }
        let epsilon = 1e-6
        let candidates = frames.filter { other in
            guard other.tabID != tabID else { return false }
            switch edge {
            case .left:
                return other.maxX <= source.x + epsilon && verticalOverlap(source, other) > epsilon
            case .right:
                return other.x >= source.maxX - epsilon && verticalOverlap(source, other) > epsilon
            case .up:
                return other.maxY <= source.y + epsilon && horizontalOverlap(source, other) > epsilon
            case .down:
                return other.y >= source.maxY - epsilon && horizontalOverlap(source, other) > epsilon
            }
        }
        return candidates.min { lhs, rhs in
            let leftDistance = separation(source, lhs, edge: edge)
            let rightDistance = separation(source, rhs, edge: edge)
            if abs(leftDistance - rightDistance) > epsilon {
                return leftDistance < rightDistance
            }
            if abs(lhs.y - rhs.y) > epsilon {
                return lhs.y < rhs.y
            }
            return lhs.x < rhs.x
        }?.tabID
    }

    /// Swaps the focused pane with its left or right neighbor. Up and down are not swap shortcuts.
    public func swapping(toward edge: TileEdge) -> TileLayout {
        guard edge == .left || edge == .right else { return self }
        guard let other = neighbor(of: focusedTabID, toward: edge) else { return self }
        return exchanging(focusedTabID, with: other)
    }

    /// Spoken place for VoiceOver, for example "right pane" or "bottom left pane".
    public func spokenPlace(of tabID: UUID) -> String {
        let frames = paneFrames()
        guard let frame = frames.first(where: { $0.tabID == tabID }) else { return "pane" }
        let centerX = frame.x + frame.width / 2
        let centerY = frame.y + frame.height / 2
        let horizontal: String
        if frame.width > 0.9 {
            horizontal = ""
        } else if centerX < 0.34 {
            horizontal = "left"
        } else if centerX > 0.66 {
            horizontal = "right"
        } else {
            horizontal = "middle"
        }
        let vertical: String
        if frame.height > 0.9 {
            vertical = ""
        } else if centerY < 0.34 {
            vertical = "top"
        } else if centerY > 0.66 {
            vertical = "bottom"
        } else {
            vertical = "middle"
        }
        let words = [vertical, horizontal].filter { !$0.isEmpty }
        if words.isEmpty {
            return "pane"
        }
        return words.joined(separator: " ") + " pane"
    }

    private func growthOrder(adding newID: UUID, beside anchor: UUID, edge: TileEdge, target: TileArrangement) -> [UUID] {
        let existing = tabIDs()
        if target == .onePlusTwo {
            let other = existing.first { $0 != anchor } ?? anchor
            switch edge {
            case .down:
                // The leading pane becomes the tall left column. 1+2 cannot put a new pane under it.
                if existing.first == anchor {
                    return []
                }
                return [other, anchor, newID]
            case .up:
                if existing.first == anchor {
                    return []
                }
                return [other, newID, anchor]
            case .left, .right:
                break
            }
        }
        var order = existing
        let index = order.firstIndex(of: anchor) ?? (order.count - 1)
        let at = (edge == .left || edge == .up) ? index : index + 1
        order.insert(newID, at: min(max(at, 0), order.count))
        return order
    }

    private static func collectFrames(
        _ node: TileNode,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        into frames: inout [TilePaneFrame]
    ) {
        switch node {
        case .pane(let pane):
            frames.append(TilePaneFrame(
                tabID: pane.tabID,
                kind: pane.kind,
                x: x,
                y: y,
                width: width,
                height: height
            ))
        case .split(let split):
            let ratios = TileLayout.sanitizedRatios(split.ratios, count: split.children.count)
            var cursor = 0.0
            for (index, child) in split.children.enumerated() {
                let share = ratios[index]
                if split.axis == .horizontal {
                    collectFrames(
                        child,
                        x: x + cursor * width,
                        y: y,
                        width: width * share,
                        height: height,
                        into: &frames
                    )
                } else {
                    collectFrames(
                        child,
                        x: x,
                        y: y + cursor * height,
                        width: width,
                        height: height * share,
                        into: &frames
                    )
                }
                cursor += share
            }
        }
    }

    private func verticalOverlap(_ lhs: TilePaneFrame, _ rhs: TilePaneFrame) -> Double {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.y, rhs.y))
    }

    private func horizontalOverlap(_ lhs: TilePaneFrame, _ rhs: TilePaneFrame) -> Double {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.x, rhs.x))
    }

    private func separation(_ source: TilePaneFrame, _ other: TilePaneFrame, edge: TileEdge) -> Double {
        switch edge {
        case .left:
            return source.x - other.maxX
        case .right:
            return other.x - source.maxX
        case .up:
            return source.y - other.maxY
        case .down:
            return other.y - source.maxY
        }
    }
}
