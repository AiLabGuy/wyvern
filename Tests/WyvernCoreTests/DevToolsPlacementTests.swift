// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class DevToolsPlacementTests: XCTestCase {
    func testUntiledOpenIsSixtyFortyOnTheRight() {
        let source = UUID()
        let plan = DevToolsPlacement.opening(
            sourceIsTiled: false,
            paneCount: 1,
            windowWidth: 1000,
            readingOrder: [source],
            source: source
        )
        XCTAssertEqual(plan, .pair(axis: .horizontal, pageFraction: 0.6, devtoolsFirst: false))
        let tools = UUID()
        let layout = DevToolsPlacement.pair(source: source, devtools: tools, axis: .horizontal, pageFraction: 0.6)
        XCTAssertEqual(layout.tabIDs(), [source, tools])
        XCTAssertEqual(layout.focusedTabID, tools)
        assertRootRatios(layout, axis: .horizontal, ratios: [0.6, 0.4])
        XCTAssertEqual(DevToolsPlacement.pageFraction(source: source, devtools: tools, in: layout) ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(DevToolsPlacement.side(of: tools, relativeTo: source, in: layout), .right)
    }

    func testNarrowWindowOpensDevToolsOnTheBottom() {
        let source = UUID()
        let atEdge = DevToolsPlacement.opening(
            sourceIsTiled: false,
            paneCount: 1,
            windowWidth: 800,
            readingOrder: [source],
            source: source
        )
        XCTAssertEqual(atEdge, .pair(axis: .horizontal, pageFraction: 0.6, devtoolsFirst: false))
        let narrow = DevToolsPlacement.opening(
            sourceIsTiled: false,
            paneCount: 1,
            windowWidth: 799,
            readingOrder: [source],
            source: source
        )
        XCTAssertEqual(narrow, .pair(axis: .vertical, pageFraction: 0.6, devtoolsFirst: false))
        let tools = UUID()
        let layout = DevToolsPlacement.pair(
            source: source,
            devtools: tools,
            axis: .vertical,
            pageFraction: 0.6,
            devtoolsFirst: false
        )
        XCTAssertEqual(layout.tabIDs(), [source, tools])
        assertRootRatios(layout, axis: .vertical, ratios: [0.6, 0.4])
        XCTAssertEqual(DevToolsPlacement.side(of: tools, relativeTo: source, in: layout), .below)
        XCTAssertEqual(layout.spokenPlace(of: tools), "bottom pane")
    }

    func testInsertRightTakesFortyPercentOfTheSourcePane() {
        let terminal = UUID()
        let source = UUID()
        let tools = UUID()
        let base = TileLayout.arranged(
            .twoColumns,
            tabs: [terminal, source],
            kinds: [.terminal, .web],
            focused: source
        )!
        let plan = DevToolsPlacement.opening(
            sourceIsTiled: true,
            paneCount: 2,
            windowWidth: 1200,
            readingOrder: base.tabIDs(),
            source: source
        )
        XCTAssertEqual(plan, .insertRight(sourceKeeps: 0.6))
        let next = base.placingDevTools(devtools: tools, beside: source, side: .right)
        XCTAssertEqual(next.tabIDs(), [terminal, source, tools])
        XCTAssertEqual(next.panes().map(\.kind), [.terminal, .web, .devtools])
        XCTAssertEqual(next.focusedTabID, tools)
        // The terminal pane keeps half. DevTools takes 40% of the source pane's old half.
        assertRootRatios(next, axis: .horizontal, ratios: [0.5, 0.3, 0.2])
        XCTAssertEqual(DevToolsPlacement.pageFraction(source: source, devtools: tools, in: next) ?? 0, 0.6, accuracy: 0.001)
    }

    func testFourPaneReplacementSelectsTheLastNonSource() {
        let panes = [UUID(), UUID(), UUID(), UUID()]
        let plan = DevToolsPlacement.opening(
            sourceIsTiled: true,
            paneCount: 4,
            windowWidth: 1400,
            readingOrder: panes,
            source: panes[1]
        )
        XCTAssertEqual(plan, .replace(panes[3]))
        XCTAssertEqual(DevToolsPlacement.paneToReplace(readingOrder: panes, source: panes[3]), panes[2])
        XCTAssertNil(DevToolsPlacement.paneToReplace(readingOrder: [panes[0]], source: panes[0]))
        let three = DevToolsPlacement.opening(
            sourceIsTiled: true,
            paneCount: 3,
            windowWidth: 1400,
            readingOrder: Array(panes.prefix(3)),
            source: panes[0]
        )
        XCTAssertEqual(three, .insertRight(sourceKeeps: 0.6))
    }

    func testMoveSidesKeepSiblingSlotsAndPageShare() {
        let terminal = UUID()
        let source = UUID()
        let tools = UUID()
        let base = TileLayout.arranged(
            .twoColumns,
            tabs: [terminal, source],
            kinds: [.terminal, .web],
            focused: source
        )!
        let right = base.placingDevTools(devtools: tools, beside: source, side: .right)
        let below = right.placingDevTools(devtools: tools, beside: source, side: .below)
        guard case .split(let columns) = below.root else {
            XCTFail("Expected a horizontal parent")
            return
        }
        XCTAssertEqual(columns.axis, .horizontal)
        XCTAssertEqual(columns.children.count, 2)
        XCTAssertEqual(columns.ratios[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(columns.ratios[1], 0.5, accuracy: 0.001)
        guard case .pane(let terminalPane) = columns.children[0] else {
            XCTFail("Terminal pane moved")
            return
        }
        XCTAssertEqual(terminalPane.tabID, terminal)
        XCTAssertEqual(terminalPane.kind, .terminal)
        guard case .split(let pair) = columns.children[1] else {
            XCTFail("Expected the page column to become a vertical pair")
            return
        }
        XCTAssertEqual(pair.axis, .vertical)
        XCTAssertEqual(pair.ratios[0], 0.6, accuracy: 0.001)
        XCTAssertEqual(pair.ratios[1], 0.4, accuracy: 0.001)
        XCTAssertEqual(below.tabIDs(), [terminal, source, tools])
        XCTAssertEqual(DevToolsPlacement.side(of: tools, relativeTo: source, in: below), .below)

        let left = below.placingDevTools(devtools: tools, beside: source, side: .left)
        XCTAssertEqual(left.tabIDs(), [terminal, tools, source])
        assertRootRatios(left, axis: .horizontal, ratios: [0.5, 0.2, 0.3])
        XCTAssertEqual(DevToolsPlacement.side(of: tools, relativeTo: source, in: left), .left)
        XCTAssertEqual(left.panes().map(\.kind), [.terminal, .devtools, .web])

        let above = left.placingDevTools(devtools: tools, beside: source, side: .above, pageFraction: 0.6)
        guard case .split(let parent) = above.root else {
            XCTFail("Expected columns")
            return
        }
        XCTAssertEqual(parent.ratios[0], 0.5, accuracy: 0.001)
        guard case .split(let stack) = parent.children[1] else {
            XCTFail("Expected a stack in the page column")
            return
        }
        XCTAssertEqual(stack.axis, .vertical)
        XCTAssertEqual(stack.ratios[0], 0.4, accuracy: 0.001)
        XCTAssertEqual(stack.ratios[1], 0.6, accuracy: 0.001)
        if case .pane(let first) = stack.children[0] {
            XCTAssertEqual(first.tabID, tools)
        } else {
            XCTFail("DevTools should be the top pane")
        }
        XCTAssertEqual(DevToolsPlacement.side(of: tools, relativeTo: source, in: above), .above)
    }

    func testStripPinsDevToolsAfterItsSource() {
        let source = UUID()
        let other = UUID()
        let tools = UUID()
        let dragged = DevToolsStrip.pinning([other, tools, source], partners: [tools: source])
        XCTAssertEqual(dragged.order, [other, source, tools])
        XCTAssertEqual(dragged.orphans, [])
        let sourceDrag = DevToolsStrip.pinning([tools, other, source], partners: [tools: source])
        XCTAssertEqual(sourceDrag.order, [other, source, tools])
        let orphan = DevToolsStrip.pinning([tools, other], partners: [tools: source])
        XCTAssertEqual(orphan.order, [other])
        XCTAssertEqual(orphan.orphans, [tools])
    }

    private func assertRootRatios(_ layout: TileLayout, axis: TileAxis, ratios: [Double]) {
        guard case .split(let split) = layout.root else {
            XCTFail("Expected a split root")
            return
        }
        XCTAssertEqual(split.axis, axis)
        XCTAssertEqual(split.ratios.count, ratios.count)
        for (index, ratio) in ratios.enumerated() where split.ratios.indices.contains(index) {
            XCTAssertEqual(split.ratios[index], ratio, accuracy: 0.001)
        }
    }
}
