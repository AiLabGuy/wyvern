// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Side by side, or stacked with the first child on top.
public enum TileAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

/// One tab inside a split. A tab appears in at most one pane.
/// `kind` is the tab's kind so a split can mix web, terminal, and DevTools.
/// Older JSON omits it and decodes as `.web`.
public struct TilePane: Equatable, Sendable, Codable {
    public var tabID: UUID
    public var kind: TabKind

    public init(tabID: UUID, kind: TabKind = .web) {
        self.tabID = tabID
        self.kind = kind
    }
}

/// An n-ary split. Children share `axis`. Nested splits use the other axis, or the same axis
/// after a wrap; `TileLayout.normalized()` flattens same-axis nesting.
public struct TileSplit: Equatable, Sendable, Codable {
    public var id: UUID
    public var axis: TileAxis
    public var children: [TileNode]
    /// Positive weights, one per child, summing to 1.
    public var ratios: [Double]

    public init(id: UUID, axis: TileAxis, children: [TileNode], ratios: [Double]) {
        self.id = id
        self.axis = axis
        self.children = children
        self.ratios = ratios
    }
}

public indirect enum TileNode: Equatable, Sendable {
    case pane(TilePane)
    case split(TileSplit)
}

extension TileNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case tabID
        case kind
        case id
        case axis
        case ratios
        case children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            let tabID = try container.decode(UUID.self, forKey: .tabID)
            let kind = try container.decodeIfPresent(TabKind.self, forKey: .kind) ?? .web
            self = .pane(TilePane(tabID: tabID, kind: kind))
        case "split":
            let id = try container.decode(UUID.self, forKey: .id)
            let axis = try container.decode(TileAxis.self, forKey: .axis)
            let ratios = try container.decode([Double].self, forKey: .ratios)
            let children = try container.decode([TileNode].self, forKey: .children)
            self = .split(TileSplit(id: id, axis: axis, children: children, ratios: ratios))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown tile node"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane.tabID, forKey: .tabID)
            if pane.kind != .web {
                try container.encode(pane.kind, forKey: .kind)
            }
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split.id, forKey: .id)
            try container.encode(split.axis, forKey: .axis)
            try container.encode(split.ratios, forKey: .ratios)
            try container.encode(split.children, forKey: .children)
        }
    }
}

/// Binary/n-ary split tree for one window.
///
/// Focus order is the reading order of the panes: left to right, and top to bottom inside a stack.
/// A layout with fewer than two panes is not a split; `removing` returns nil in that case.
public struct TileLayout: Equatable, Sendable {
    /// Vertical minimum used by the original ratio tests. Horizontal panes use `minimumPaneWidth`.
    public static let minimumPanePoints: Double = 200
    public static let minimumPaneWidth: Double = 320
    public static let minimumPaneHeight: Double = 200
    /// Divider snaps when the pointer is within this many points of 1/3, 1/2, or 2/3.
    public static let snapTolerance: Double = 8
    public static let snapTargets: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0]

    public var root: TileNode
    public var focusedTabID: UUID

    public init(root: TileNode, focusedTabID: UUID) {
        self.root = Self.normalizedRoot(root) ?? root
        let ids = Self.tabIDs(in: self.root)
        if ids.contains(focusedTabID) {
            self.focusedTabID = focusedTabID
        } else {
            self.focusedTabID = ids.first ?? focusedTabID
        }
    }

    /// Two panes, `newTab` focused and placed after `anchor`.
    public static func split(
        anchor: UUID,
        newTab: UUID,
        axis: TileAxis,
        splitID: UUID = UUID()
    ) -> TileLayout {
        TileLayout(
            root: .split(TileSplit(
                id: splitID,
                axis: axis,
                children: [
                    .pane(TilePane(tabID: anchor)),
                    .pane(TilePane(tabID: newTab))
                ],
                ratios: [0.5, 0.5]
            )),
            focusedTabID: newTab
        )
    }

    public var isSplit: Bool {
        tabIDs().count >= 2
    }

    public func contains(_ tabID: UUID) -> Bool {
        tabIDs().contains(tabID)
    }

    /// Reading order. Horizontal children run left to right. Vertical children run top to bottom.
    public func tabIDs() -> [UUID] {
        Self.tabIDs(in: root)
    }

    public func normalized() -> TileLayout {
        TileLayout(root: root, focusedTabID: focusedTabID)
    }

    /// Splits `anchorTabID` along `axis`. The same axis grows that split; the other axis nests.
    /// The new pane takes half of the anchor's share and becomes focused.
    /// A fifth pane is refused. Split View holds at most four tabs.
    public func adding(tabID: UUID, beside anchorTabID: UUID, axis: TileAxis, splitID: UUID = UUID()) -> TileLayout {
        guard tabID != anchorTabID, !contains(tabID), contains(anchorTabID) else { return self }
        guard tabIDs().count < TileArrangement.maximumPanes else { return self }
        var node = root
        guard Self.insert(tabID, beside: anchorTabID, axis: axis, splitID: splitID, into: &node) else {
            return self
        }
        return TileLayout(root: node, focusedTabID: tabID)
    }

    /// Drops the pane. One remaining pane, or none, collapses the split (`nil`).
    /// Focus moves to the next pane in reading order, or the previous pane when the last one closes.
    public func removing(tabID: UUID) -> TileLayout? {
        guard contains(tabID) else { return self }
        guard let focus = focus(afterRemoving: tabID) else { return nil }
        var node = root
        guard Self.detach(tabID, from: &node) else { return nil }
        let layout = TileLayout(root: node, focusedTabID: focus)
        return layout.isSplit ? layout : nil
    }

    /// The tab that should be focused after `tabID` leaves the tree.
    /// A missing id leaves the current focus alone. Removing the last tab returns nil.
    public func focus(afterRemoving tabID: UUID) -> UUID? {
        let order = tabIDs()
        guard let index = order.firstIndex(of: tabID) else { return focusedTabID }
        let remaining = order.filter { $0 != tabID }
        if focusedTabID != tabID {
            return remaining.contains(focusedTabID) ? focusedTabID : remaining.first
        }
        guard !remaining.isEmpty else { return nil }
        return remaining[min(index, remaining.count - 1)]
    }

    /// Detaches `tabID` and places it on `edge` of `anchorTabID`.
    /// Left and up land immediately before the anchor. Right and down land immediately after it.
    public func moving(tabID: UUID, beside anchorTabID: UUID, edge: TileEdge, splitID: UUID = UUID()) -> TileLayout {
        let axis: TileAxis = (edge == .up || edge == .down) ? .vertical : .horizontal
        let moved = moving(tabID: tabID, beside: anchorTabID, axis: axis, splitID: splitID)
        guard edge == .left || edge == .up else { return moved }
        let order = moved.tabIDs()
        guard let anchorIndex = order.firstIndex(of: anchorTabID),
              anchorIndex + 1 < order.count,
              order[anchorIndex + 1] == tabID else {
            return moved
        }
        return moved.exchanging(tabID, with: anchorTabID)
    }

    /// Detaches `tabID` and places it just after `anchorTabID` along `axis`.
    public func moving(tabID: UUID, beside anchorTabID: UUID, axis: TileAxis, splitID: UUID = UUID()) -> TileLayout {
        guard tabID != anchorTabID, contains(tabID), contains(anchorTabID) else { return self }
        let focus = focusedTabID
        var node = root
        guard Self.detach(tabID, from: &node) else { return self }
        let carriedFocus = Self.tabIDs(in: node).contains(anchorTabID) ? anchorTabID : tabID
        let carried = TileLayout(root: node, focusedTabID: carriedFocus)
        let inserted = carried.adding(tabID: tabID, beside: anchorTabID, axis: axis, splitID: splitID)
        guard inserted.contains(tabID), inserted.contains(anchorTabID) else { return self }
        if inserted.contains(focus) {
            return inserted.focusing(focus)
        }
        return inserted
    }

    public func focusing(_ tabID: UUID) -> TileLayout {
        guard contains(tabID) else { return self }
        var copy = self
        copy.focusedTabID = tabID
        return copy
    }

    /// Next or previous pane in reading order, wrapping.
    public func focusingNext(forward: Bool) -> TileLayout {
        let order = tabIDs()
        guard !order.isEmpty else { return self }
        guard let index = order.firstIndex(of: focusedTabID) else {
            return focusing(order[0])
        }
        let step = forward ? 1 : -1
        let next = (index + step + order.count) % order.count
        return focusing(order[next])
    }

    /// Drags the divider between child `divider` and the next child.
    /// `proposedRatio` is the desired absolute share of the leading child.
    /// Other children keep their shares. Both sides of the divider stay at least `minimum` points
    /// when `length` can hold that, and split the pair when it cannot.
    public func resizing(
        splitID: UUID,
        divider: Int,
        proposedRatio: Double,
        length: Double,
        minimum: Double = TileLayout.minimumPanePoints
    ) -> TileLayout {
        var node = root
        Self.resize(
            &node,
            splitID: splitID,
            divider: divider,
            proposedRatio: proposedRatio,
            length: length,
            minimum: minimum
        )
        return TileLayout(root: node, focusedTabID: focusedTabID)
    }

    /// Equal share for every child of every split.
    public func equalized() -> TileLayout {
        TileLayout(root: Self.equalizeAll(root), focusedTabID: focusedTabID)
    }

    /// Equal share for the children of one split.
    public func equalizing(splitID: UUID) -> TileLayout {
        var node = root
        Self.equalize(&node, splitID: splitID)
        return TileLayout(root: node, focusedTabID: focusedTabID)
    }

    public func split(id: UUID) -> TileSplit? {
        Self.findSplit(id, in: root)
    }

    /// Lifts ratios up to `minimum / length`, taking the extra from siblings that can spare it.
    /// When the length cannot hold every pane at `minimum`, the result is an even split.
    public static func clampRatios(_ ratios: [Double], length: Double, minimum: Double) -> [Double] {
        let count = ratios.count
        guard count > 0 else { return [] }
        let even = Self.sanitizedRatios([], count: count)
        guard length > 0, minimum > 0 else { return Self.sanitizedRatios(ratios, count: count) }
        let minFraction = minimum / length
        if minFraction * Double(count) >= 1 - 1e-9 {
            return even
        }
        var result = Self.sanitizedRatios(ratios, count: count)
        var frozen = Array(repeating: false, count: count)
        for _ in 0..<count {
            var raised = false
            for index in 0..<count where !frozen[index] && result[index] < minFraction - 1e-12 {
                result[index] = minFraction
                frozen[index] = true
                raised = true
            }
            let frozenSum = zip(result, frozen).reduce(0.0) { partial, pair in
                pair.1 ? partial + pair.0 : partial
            }
            let flexible = (0..<count).filter { !frozen[$0] }
            guard !flexible.isEmpty else { break }
            let remain = max(0, 1 - frozenSum)
            let flexSum = flexible.reduce(0.0) { $0 + result[$1] }
            if flexSum <= 0 {
                let share = remain / Double(flexible.count)
                for index in flexible {
                    result[index] = share
                }
            } else {
                for index in flexible {
                    result[index] = result[index] / flexSum * remain
                }
            }
            if !raised { break }
        }
        return Self.sanitizedRatios(result, count: count)
    }

    /// Resizes the pair around `divider`. The pair's combined share stays put.
    public static func resizeDivider(
        ratios: [Double],
        divider: Int,
        proposedRatio: Double,
        length: Double,
        minimum: Double
    ) -> [Double] {
        guard ratios.indices.contains(divider), divider + 1 < ratios.count else { return ratios }
        guard proposedRatio.isFinite else { return ratios }
        var next = Self.sanitizedRatios(ratios, count: ratios.count)
        let pair = next[divider] + next[divider + 1]
        guard pair > 0 else { return next }
        let minFraction: Double
        if length <= 0 || minimum <= 0 {
            minFraction = 0
        } else {
            minFraction = minimum / length
        }
        let lower: Double
        let upper: Double
        if minFraction * 2 >= pair {
            lower = pair / 2
            upper = pair / 2
        } else {
            lower = minFraction
            upper = pair - minFraction
        }
        let leading = min(max(proposedRatio, lower), upper)
        next[divider] = leading
        next[divider + 1] = pair - leading
        return next
    }

    public static func sanitizedRatios(_ ratios: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let even = 1 / Double(count)
        guard ratios.count == count else {
            return Array(repeating: even, count: count)
        }
        let cleaned = ratios.map { value -> Double in
            if value.isFinite, value > 0 { return value }
            return 0
        }
        let sum = cleaned.reduce(0, +)
        guard sum > 0 else { return Array(repeating: even, count: count) }
        return cleaned.map { $0 / sum }
    }

    /// Collapses single-child splits, flattens same-axis nesting, drops duplicate tabs, and repairs ratios.
    public static func normalizedRoot(_ node: TileNode) -> TileNode? {
        var seen = Set<UUID>()
        return normalize(node, seen: &seen)
    }

    public func sessionSnapshot(indexOfTab: (UUID) -> Int?) -> SessionTileSnapshot? {
        guard let root = SessionTileNode.captured(from: self.root, indexOf: indexOfTab) else { return nil }
        guard root.paneCount >= 2 else { return nil }
        let focused = indexOfTab(focusedTabID) ?? root.firstTabIndex ?? 0
        return SessionTileSnapshot(focusedTabIndex: focused, root: root)
    }

    public static func restored(_ snapshot: SessionTileSnapshot, tabID: (Int) -> UUID?) -> TileLayout? {
        guard let root = TileNode.restored(snapshot.root, tabID: tabID) else { return nil }
        let ids = tabIDs(in: root)
        guard ids.count >= 2 else { return nil }
        let focus = tabID(snapshot.focusedTabIndex) ?? ids[0]
        let resolved = ids.contains(focus) ? focus : ids[0]
        return TileLayout(root: root, focusedTabID: resolved)
    }

    /// Reading order, including each pane's kind.
    public func panes() -> [TilePane] {
        Self.collectPanes(in: root)
    }

    /// Swaps one pane's tab for another without changing the tree or the ratios.
    /// Focus follows the old id when that pane was focused.
    public func replacing(tabID: UUID, with newID: UUID, kind: TabKind) -> TileLayout {
        guard contains(tabID), newID != tabID, !contains(newID) else { return self }
        let node = Self.mapPanes(root) { pane in
            pane.tabID == tabID ? TilePane(tabID: newID, kind: kind) : pane
        }
        let focus = focusedTabID == tabID ? newID : focusedTabID
        return TileLayout(root: node, focusedTabID: focus)
    }

    /// Drops every pane whose tab is not in `ids`. Fewer than two panes collapses the split.
    public func pruning(keeping ids: Set<UUID>) -> TileLayout? {
        var current: TileLayout? = self
        for id in tabIDs() where !ids.contains(id) {
            guard let layout = current else { return nil }
            current = layout.removing(tabID: id)
        }
        return current
    }

    /// Writes the kind reported by the session onto each pane. Unknown tabs stay as they are.
    public func applyingKinds(_ kindFor: (UUID) -> TabKind?) -> TileLayout {
        let node = Self.mapPanes(root) { pane in
            guard let kind = kindFor(pane.tabID), kind != pane.kind else { return pane }
            return TilePane(tabID: pane.tabID, kind: kind)
        }
        return TileLayout(root: node, focusedTabID: focusedTabID)
    }

    /// Replaces the ratios of one split. Used while an equalize animation is in flight.
    public func settingRatios(splitID: UUID, ratios: [Double]) -> TileLayout {
        var node = root
        Self.writeRatios(&node, splitID: splitID, ratios: ratios)
        return TileLayout(root: node, focusedTabID: focusedTabID)
    }

    /// Exchanges two panes' tabs and kinds. Focus stays on the same tab, which moves with it.
    public func exchanging(_ first: UUID, with second: UUID) -> TileLayout {
        guard first != second, contains(first), contains(second) else { return self }
        let records = panes()
        guard let paneA = records.first(where: { $0.tabID == first }),
              let paneB = records.first(where: { $0.tabID == second }) else {
            return self
        }
        let node = Self.mapPanes(root) { pane in
            if pane.tabID == first { return TilePane(tabID: second, kind: paneB.kind) }
            if pane.tabID == second { return TilePane(tabID: first, kind: paneA.kind) }
            return pane
        }
        return TileLayout(root: node, focusedTabID: focusedTabID)
    }

    /// Snaps `fraction` (0...1 along the split) to 1/3, 1/2, 2/3, and any extra targets, within `tolerance` points.
    public static func snapFraction(
        _ fraction: Double,
        length: Double,
        tolerance: Double = TileLayout.snapTolerance,
        extraTargets: [Double] = []
    ) -> (fraction: Double, snapped: Bool) {
        guard length > 0, fraction.isFinite, tolerance >= 0 else { return (fraction, false) }
        let window = tolerance / length
        var best: Double?
        var bestDistance = Double.greatestFiniteMagnitude
        for target in snapTargets + extraTargets where target.isFinite {
            let distance = abs(fraction - target)
            if distance <= window + 1e-12, distance < bestDistance - 1e-15 {
                best = target
                bestDistance = distance
            }
        }
        if let best {
            return (best, true)
        }
        return (fraction, false)
    }
}

extension TileLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case root
        case focusedTabID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let root = try container.decode(TileNode.self, forKey: .root)
        let focused = try container.decode(UUID.self, forKey: .focusedTabID)
        self.init(root: root, focusedTabID: focused)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encode(focusedTabID, forKey: .focusedTabID)
    }
}

/// Tile tree stored on a window snapshot. Panes point at tab indexes so restore can mint new ids.
public struct SessionTileSnapshot: Equatable, Sendable {
    public var focusedTabIndex: Int
    public var root: SessionTileNode

    public init(focusedTabIndex: Int, root: SessionTileNode) {
        self.focusedTabIndex = focusedTabIndex
        self.root = root
    }
}

extension SessionTileSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case focusedTabIndex
        case root
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        focusedTabIndex = try container.decodeIfPresent(Int.self, forKey: .focusedTabIndex) ?? 0
        root = try container.decode(SessionTileNode.self, forKey: .root)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(focusedTabIndex, forKey: .focusedTabIndex)
        try container.encode(root, forKey: .root)
    }
}

public indirect enum SessionTileNode: Equatable, Sendable {
    case pane(tabIndex: Int)
    case split(axis: TileAxis, ratios: [Double], children: [SessionTileNode])

    var paneCount: Int {
        switch self {
        case .pane:
            return 1
        case .split(_, _, let children):
            return children.reduce(0) { $0 + $1.paneCount }
        }
    }

    var firstTabIndex: Int? {
        switch self {
        case .pane(let index):
            return index
        case .split(_, _, let children):
            for child in children {
                if let index = child.firstTabIndex { return index }
            }
            return nil
        }
    }

    static func captured(from node: TileNode, indexOf: (UUID) -> Int?) -> SessionTileNode? {
        switch node {
        case .pane(let pane):
            guard let index = indexOf(pane.tabID), index >= 0 else { return nil }
            return .pane(tabIndex: index)
        case .split(let split):
            let clean = TileLayout.sanitizedRatios(split.ratios, count: split.children.count)
            var children: [SessionTileNode] = []
            var ratios: [Double] = []
            for (offset, child) in split.children.enumerated() {
                guard let captured = captured(from: child, indexOf: indexOf) else { continue }
                children.append(captured)
                ratios.append(clean[offset])
            }
            if children.count == 1 { return children[0] }
            if children.isEmpty { return nil }
            return .split(
                axis: split.axis,
                ratios: TileLayout.sanitizedRatios(ratios, count: children.count),
                children: children
            )
        }
    }
}

extension SessionTileNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case tabIndex
        case axis
        case ratios
        case children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let index = try container.decodeIfPresent(Int.self, forKey: .tabIndex) {
            self = .pane(tabIndex: index)
            return
        }
        let axis = try container.decode(TileAxis.self, forKey: .axis)
        let ratios = try container.decodeIfPresent([Double].self, forKey: .ratios) ?? []
        let children = try container.decodeIfPresent([SessionTileNode].self, forKey: .children) ?? []
        self = .split(axis: axis, ratios: ratios, children: children)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let index):
            try container.encode(index, forKey: .tabIndex)
        case .split(let axis, let ratios, let children):
            try container.encode(axis, forKey: .axis)
            try container.encode(ratios, forKey: .ratios)
            try container.encode(children, forKey: .children)
        }
    }
}

extension TileNode {
    static func restored(_ node: SessionTileNode, tabID: (Int) -> UUID?) -> TileNode? {
        switch node {
        case .pane(let index):
            guard index >= 0, let id = tabID(index) else { return nil }
            return .pane(TilePane(tabID: id))
        case .split(let axis, let ratios, let children):
            var built: [TileNode] = []
            var weights: [Double] = []
            let clean = TileLayout.sanitizedRatios(ratios, count: children.count)
            for (offset, child) in children.enumerated() {
                guard let restored = restored(child, tabID: tabID) else { continue }
                built.append(restored)
                let weight = offset < clean.count ? clean[offset] : 0
                weights.append(weight)
            }
            guard !built.isEmpty else { return nil }
            if built.count == 1 { return built[0] }
            return .split(TileSplit(
                id: UUID(),
                axis: axis,
                children: built,
                ratios: weights
            ))
        }
    }
}

extension TileLayout {
    private static func collectPanes(in node: TileNode) -> [TilePane] {
        switch node {
        case .pane(let pane):
            return [pane]
        case .split(let split):
            return split.children.flatMap { collectPanes(in: $0) }
        }
    }

    static func mapPanes(_ node: TileNode, _ body: (TilePane) -> TilePane) -> TileNode {
        switch node {
        case .pane(let pane):
            return .pane(body(pane))
        case .split(var split):
            split.children = split.children.map { mapPanes($0, body) }
            return .split(split)
        }
    }

    private static func writeRatios(_ node: inout TileNode, splitID: UUID, ratios: [Double]) {
        guard case .split(var split) = node else { return }
        if split.id == splitID {
            split.ratios = sanitizedRatios(ratios, count: split.children.count)
            node = .split(split)
            return
        }
        for index in split.children.indices {
            writeRatios(&split.children[index], splitID: splitID, ratios: ratios)
        }
        node = .split(split)
    }

    private static func tabIDs(in node: TileNode) -> [UUID] {
        switch node {
        case .pane(let pane):
            return [pane.tabID]
        case .split(let split):
            return split.children.flatMap { tabIDs(in: $0) }
        }
    }

    private static func normalize(_ node: TileNode, seen: inout Set<UUID>) -> TileNode? {
        switch node {
        case .pane(let pane):
            if !seen.insert(pane.tabID).inserted { return nil }
            return .pane(pane)
        case .split(let split):
            let clean = sanitizedRatios(split.ratios, count: split.children.count)
            var children: [TileNode] = []
            var ratios: [Double] = []
            for (offset, child) in split.children.enumerated() {
                guard let next = normalize(child, seen: &seen) else { continue }
                if case .split(let inner) = next, inner.axis == split.axis {
                    let innerRatios = sanitizedRatios(inner.ratios, count: inner.children.count)
                    for (innerOffset, grandchild) in inner.children.enumerated() {
                        children.append(grandchild)
                        ratios.append(clean[offset] * innerRatios[innerOffset])
                    }
                } else {
                    children.append(next)
                    ratios.append(clean[offset])
                }
            }
            if children.isEmpty { return nil }
            if children.count == 1 { return children[0] }
            return .split(TileSplit(
                id: split.id,
                axis: split.axis,
                children: children,
                ratios: sanitizedRatios(ratios, count: children.count)
            ))
        }
    }

    private static func insert(
        _ tabID: UUID,
        beside anchorTabID: UUID,
        axis: TileAxis,
        splitID: UUID,
        into node: inout TileNode
    ) -> Bool {
        switch node {
        case .pane(let pane):
            guard pane.tabID == anchorTabID else { return false }
            node = .split(TileSplit(
                id: splitID,
                axis: axis,
                children: [.pane(pane), .pane(TilePane(tabID: tabID))],
                ratios: [0.5, 0.5]
            ))
            return true
        case .split(var split):
            split.ratios = sanitizedRatios(split.ratios, count: split.children.count)
            for index in split.children.indices {
                if case .pane(let pane) = split.children[index], pane.tabID == anchorTabID, split.axis == axis {
                    let share = split.ratios[index]
                    let half = share / 2
                    split.ratios[index] = half
                    split.children.insert(.pane(TilePane(tabID: tabID)), at: index + 1)
                    split.ratios.insert(half, at: index + 1)
                    node = .split(split)
                    return true
                }
            }
            for index in split.children.indices {
                if insert(tabID, beside: anchorTabID, axis: axis, splitID: splitID, into: &split.children[index]) {
                    node = .split(split)
                    return true
                }
            }
            return false
        }
    }

    /// Removes the pane. A split that loses its last sibling collapses to the remaining child.
    private static func detach(_ tabID: UUID, from node: inout TileNode) -> Bool {
        if case .pane(let pane) = node, pane.tabID == tabID {
            return false
        }
        switch node {
        case .pane:
            return false
        case .split(var split):
            split.ratios = sanitizedRatios(split.ratios, count: split.children.count)
            if let index = split.children.firstIndex(where: { child in
                if case .pane(let pane) = child { return pane.tabID == tabID }
                return false
            }) {
                split.children.remove(at: index)
                split.ratios.remove(at: index)
                if split.children.count == 1 {
                    node = split.children[0]
                } else if split.children.isEmpty {
                    return false
                } else {
                    node = .split(split)
                }
                return true
            }
            for index in split.children.indices {
                if detach(tabID, from: &split.children[index]) {
                    if split.children.count == 1 {
                        node = split.children[0]
                    } else {
                        node = .split(split)
                    }
                    return true
                }
            }
            return false
        }
    }

    private static func resize(
        _ node: inout TileNode,
        splitID: UUID,
        divider: Int,
        proposedRatio: Double,
        length: Double,
        minimum: Double
    ) {
        guard case .split(var split) = node else { return }
        if split.id == splitID {
            split.ratios = resizeDivider(
                ratios: split.ratios,
                divider: divider,
                proposedRatio: proposedRatio,
                length: length,
                minimum: minimum
            )
            node = .split(split)
            return
        }
        for index in split.children.indices {
            resize(
                &split.children[index],
                splitID: splitID,
                divider: divider,
                proposedRatio: proposedRatio,
                length: length,
                minimum: minimum
            )
        }
        node = .split(split)
    }

    private static func equalizeAll(_ node: TileNode) -> TileNode {
        switch node {
        case .pane:
            return node
        case .split(var split):
            split.children = split.children.map { equalizeAll($0) }
            let count = split.children.count
            split.ratios = sanitizedRatios([], count: count)
            return .split(split)
        }
    }

    private static func equalize(_ node: inout TileNode, splitID: UUID) {
        guard case .split(var split) = node else { return }
        if split.id == splitID {
            split.ratios = sanitizedRatios([], count: split.children.count)
            node = .split(split)
            return
        }
        for index in split.children.indices {
            equalize(&split.children[index], splitID: splitID)
        }
        node = .split(split)
    }

    private static func findSplit(_ id: UUID, in node: TileNode) -> TileSplit? {
        guard case .split(let split) = node else { return nil }
        if split.id == id { return split }
        for child in split.children {
            if let found = findSplit(id, in: child) { return found }
        }
        return nil
    }
}
