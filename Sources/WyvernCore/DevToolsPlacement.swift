// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where a DevTools pane sits relative to its source page.
public enum DevToolsSide: String, Codable, Equatable, Sendable {
    case left
    case right
    case above
    case below

    public var axis: TileAxis {
        switch self {
        case .left, .right:
            return .horizontal
        case .above, .below:
            return .vertical
        }
    }

    /// Left and above put DevTools first. The page still keeps `pageFraction`.
    public var devtoolsFirst: Bool {
        self == .left || self == .above
    }

    public var edge: TileEdge {
        switch self {
        case .left: return .left
        case .right: return .right
        case .above: return .up
        case .below: return .down
        }
    }

    public init(edge: TileEdge) {
        switch edge {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .above
        case .down: self = .below
        }
    }

    public var dropLabel: String {
        switch self {
        case .left: return "Place DevTools on the left"
        case .right: return "Place DevTools on the right"
        case .above: return "Place DevTools on the top"
        case .below: return "Place DevTools on the bottom"
        }
    }

    public var moveAnnouncement: String {
        switch self {
        case .left: return "Moved DevTools left of page"
        case .right: return "Moved DevTools right of page"
        case .above: return "Moved DevTools above page"
        case .below: return "Moved DevTools below page"
        }
    }

    public var menuTitle: String {
        switch self {
        case .left: return "Left of Page"
        case .right: return "Right of Page"
        case .above: return "Above Page"
        case .below: return "Below Page"
        }
    }
}

/// How opening DevTools places it. The window applies the plan; the numbers live here.
public enum DevToolsOpenPlan: Equatable, Sendable {
    /// Source is not in a split. `pageFraction` is the page's share.
    case pair(axis: TileAxis, pageFraction: Double, devtoolsFirst: Bool)
    /// Source is tiled and a pane is free. The new pane takes `1 - sourceKeeps` of the source pane's width.
    case insertRight(sourceKeeps: Double)
    /// Four panes. This tab leaves the split and returns to the strip. It is not closed.
    case replace(UUID)
}

/// Placement rules for a DevTools tab. Ratios are pure; the window does not invent a sixth layout.
public enum DevToolsPlacement {
    public static let pageFraction: Double = 0.6
    /// Below this window width an untiled open uses a bottom row instead of a right column.
    public static let narrowWidth: Double = 800

    public static func opening(
        sourceIsTiled: Bool,
        paneCount: Int,
        windowWidth: Double,
        readingOrder: [UUID],
        source: UUID
    ) -> DevToolsOpenPlan {
        if sourceIsTiled, paneCount >= 2 {
            if paneCount >= TileArrangement.maximumPanes, let victim = paneToReplace(readingOrder: readingOrder, source: source) {
                return .replace(victim)
            }
            return .insertRight(sourceKeeps: pageFraction)
        }
        let narrow = windowWidth < narrowWidth
        return .pair(
            axis: narrow ? .vertical : .horizontal,
            pageFraction: pageFraction,
            devtoolsFirst: false
        )
    }

    /// Last pane in reading order that is not the source.
    public static func paneToReplace(readingOrder: [UUID], source: UUID) -> UUID? {
        readingOrder.last { $0 != source }
    }

    /// A fresh two-pane split. The page keeps `pageFraction`. Focus is DevTools.
    public static func pair(
        source: UUID,
        devtools: UUID,
        axis: TileAxis,
        pageFraction: Double = pageFraction,
        devtoolsFirst: Bool = false,
        sourceKind: TabKind = .web,
        devtoolsKind: TabKind = .devtools
    ) -> TileLayout {
        let side: DevToolsSide
        if axis == .vertical {
            side = devtoolsFirst ? .above : .below
        } else {
            side = devtoolsFirst ? .left : .right
        }
        let root = DevToolsTree.pairNode(
            source: source,
            devtools: devtools,
            side: side,
            pageFraction: pageFraction,
            sourceKind: sourceKind,
            devtoolsKind: devtoolsKind
        )
        return TileLayout(root: root, focusedTabID: devtools)
    }

    /// The page's share of the page+DevTools slot, when both panes share a parent.
    public static func pageFraction(source: UUID, devtools: UUID, in layout: TileLayout) -> Double? {
        DevToolsTree.pageFraction(source: source, devtools: devtools, in: layout.root)
    }

    /// Side of DevTools relative to the source, from pane frames. `y` grows downward.
    public static func side(of devtools: UUID, relativeTo source: UUID, in layout: TileLayout) -> DevToolsSide? {
        let frames = layout.paneFrames()
        guard let page = frames.first(where: { $0.tabID == source }),
              let tools = frames.first(where: { $0.tabID == devtools }) else {
            return nil
        }
        let dx = (tools.x + tools.width / 2) - (page.x + page.width / 2)
        let dy = (tools.y + tools.height / 2) - (page.y + page.height / 2)
        if abs(dx) < 1e-6, abs(dy) < 1e-6 {
            return nil
        }
        if abs(dx) >= abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .above : .below
    }
}

extension TileLayout {
    /// Re-lays DevTools beside `source` at 60/40. The page keeps `pageFraction` of the pair.
    /// Same-axis parents flatten, so a sibling pane keeps its share and the new pane takes
    /// `1 - pageFraction` of the source pane's old share. Other panes keep their slots.
    public func placingDevTools(
        devtools: UUID,
        beside source: UUID,
        side: DevToolsSide,
        pageFraction: Double = DevToolsPlacement.pageFraction,
        devtoolsKind: TabKind = .devtools
    ) -> TileLayout {
        guard devtools != source, contains(source) else { return self }
        let sourceKind = panes().first { $0.tabID == source }?.kind ?? .web
        let node = DevToolsTree.place(
            root: root,
            devtools: devtools,
            source: source,
            side: side,
            pageFraction: pageFraction,
            sourceKind: sourceKind,
            devtoolsKind: devtoolsKind
        )
        return TileLayout(root: node, focusedTabID: devtools)
    }
}

/// Strip order: each DevTools tab sits immediately after its source.
public struct DevToolsStripPlan: Equatable, Sendable {
    public var order: [UUID]
    public var orphans: [UUID]

    public init(order: [UUID], orphans: [UUID]) {
        self.order = order
        self.orphans = orphans
    }
}

public enum DevToolsStrip {
    /// `partners` maps a DevTools tab id to its source tab id.
    /// A partner whose source is missing is listed in `orphans` and left out of `order`.
    public static func pinning(_ ids: [UUID], partners: [UUID: UUID]) -> DevToolsStripPlan {
        let tools = ids.filter { partners[$0] != nil }
        var result = ids.filter { partners[$0] == nil }
        var orphans: [UUID] = []
        for tool in tools {
            guard let source = partners[tool], let index = result.firstIndex(of: source) else {
                orphans.append(tool)
                continue
            }
            result.insert(tool, at: index + 1)
        }
        return DevToolsStripPlan(order: result, orphans: orphans)
    }
}

enum DevToolsTree {
    static func place(
        root: TileNode,
        devtools: UUID,
        source: UUID,
        side: DevToolsSide,
        pageFraction: Double,
        sourceKind: TabKind,
        devtoolsKind: TabKind
    ) -> TileNode {
        var node = root
        if contains(devtools, node) {
            node = detach(devtools, givingShareTo: source, from: node)
                ?? .pane(TilePane(tabID: source, kind: sourceKind))
        }
        let pair = pairNode(
            source: source,
            devtools: devtools,
            side: side,
            pageFraction: pageFraction,
            sourceKind: sourceKind,
            devtoolsKind: devtoolsKind
        )
        return replace(source, with: pair, in: node) ?? pair
    }

    static func pairNode(
        source: UUID,
        devtools: UUID,
        side: DevToolsSide,
        pageFraction: Double,
        sourceKind: TabKind,
        devtoolsKind: TabKind
    ) -> TileNode {
        let fraction = min(0.95, max(0.05, pageFraction))
        let page = TileNode.pane(TilePane(tabID: source, kind: sourceKind))
        let tools = TileNode.pane(TilePane(tabID: devtools, kind: devtoolsKind))
        let children: [TileNode]
        let ratios: [Double]
        if side.devtoolsFirst {
            children = [tools, page]
            ratios = [1 - fraction, fraction]
        } else {
            children = [page, tools]
            ratios = [fraction, 1 - fraction]
        }
        return .split(TileSplit(id: UUID(), axis: side.axis, children: children, ratios: ratios))
    }

    static func pageFraction(source: UUID, devtools: UUID, in node: TileNode) -> Double? {
        switch node {
        case .pane:
            return nil
        case .split(let split):
            let sourceIndex = split.children.firstIndex { isPane($0, source) }
            let toolsIndex = split.children.firstIndex { isPane($0, devtools) }
            if let sourceIndex, let toolsIndex,
               split.ratios.indices.contains(sourceIndex),
               split.ratios.indices.contains(toolsIndex) {
                let page = split.ratios[sourceIndex]
                let tools = split.ratios[toolsIndex]
                let total = page + tools
                if total > 0 {
                    return page / total
                }
            }
            for child in split.children {
                if let found = pageFraction(source: source, devtools: devtools, in: child) {
                    return found
                }
            }
            return nil
        }
    }

    private static func contains(_ tabID: UUID, _ node: TileNode) -> Bool {
        switch node {
        case .pane(let pane):
            return pane.tabID == tabID
        case .split(let split):
            return split.children.contains { contains(tabID, $0) }
        }
    }

    private static func isPane(_ node: TileNode, _ tabID: UUID) -> Bool {
        if case .pane(let pane) = node {
            return pane.tabID == tabID
        }
        return false
    }

    /// Removes `tabID` and adds its ratio to the sibling that holds `beneficiary`.
    /// A split that loses its last sibling collapses. `nil` means this node was the removed pane.
    private static func detach(_ tabID: UUID, givingShareTo beneficiary: UUID, from node: TileNode) -> TileNode? {
        switch node {
        case .pane(let pane):
            return pane.tabID == tabID ? nil : node
        case .split(let split):
            if let index = split.children.firstIndex(where: { isPane($0, tabID) }) {
                var children = split.children
                var ratios = split.ratios
                let removed = index < ratios.count ? ratios[index] : 0
                children.remove(at: index)
                if index < ratios.count {
                    ratios.remove(at: index)
                }
                if let host = children.firstIndex(where: { contains(beneficiary, $0) }), host < ratios.count {
                    ratios[host] += removed
                }
                if children.isEmpty { return nil }
                if children.count == 1 { return children[0] }
                return .split(TileSplit(id: split.id, axis: split.axis, children: children, ratios: ratios))
            }
            var children: [TileNode] = []
            var ratios: [Double] = []
            var changed = false
            for (index, child) in split.children.enumerated() {
                let ratio = index < split.ratios.count ? split.ratios[index] : 0
                guard contains(tabID, child) else {
                    children.append(child)
                    ratios.append(ratio)
                    continue
                }
                changed = true
                if let next = detach(tabID, givingShareTo: beneficiary, from: child) {
                    children.append(next)
                    ratios.append(ratio)
                }
            }
            if !changed { return node }
            if children.isEmpty { return nil }
            if children.count == 1 { return children[0] }
            return .split(TileSplit(id: split.id, axis: split.axis, children: children, ratios: ratios))
        }
    }

    private static func replace(_ tabID: UUID, with replacement: TileNode, in node: TileNode) -> TileNode? {
        switch node {
        case .pane(let pane):
            return pane.tabID == tabID ? replacement : nil
        case .split(var split):
            var found = false
            for index in split.children.indices {
                guard let next = replace(tabID, with: replacement, in: split.children[index]) else { continue }
                split.children[index] = next
                found = true
                break
            }
            return found ? .split(split) : nil
        }
    }
}
