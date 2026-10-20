// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class TileLayoutTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let d = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

    func testSplitRightAddsAFocusedSibling() {
        let splitID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal, splitID: splitID)
        XCTAssertEqual(layout.tabIDs(), [a, b])
        XCTAssertEqual(layout.focusedTabID, b)
        XCTAssertEqual(layout.rootSplit?.id, splitID)
        XCTAssertEqual(layout.rootSplit?.axis, .horizontal)
        XCTAssertEqual(layout.rootSplit?.ratios ?? [], [0.5, 0.5])
        XCTAssertTrue(layout.isSplit)
        XCTAssertEqual(TileLayout.minimumPanePoints, 200)
    }

    func testSameAxisAddGrowsTheSplitAndHalvesTheAnchor() {
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal)
            .adding(tabID: c, beside: a, axis: .horizontal)
        XCTAssertEqual(layout.tabIDs(), [a, c, b])
        XCTAssertEqual(layout.focusedTabID, c)
        XCTAssertEqual(layout.rootSplit?.axis, .horizontal)
        assertRatios(layout.rootSplit?.ratios ?? [], [0.25, 0.25, 0.5])
    }

    func testCrossAxisAddNestsAndKeepsTheOuterShare() {
        let outer = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let inner = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal, splitID: outer)
            .adding(tabID: c, beside: b, axis: .vertical, splitID: inner)
        XCTAssertEqual(layout.tabIDs(), [a, b, c])
        XCTAssertEqual(layout.focusedTabID, c)
        guard case .split(let root) = layout.root else {
            return XCTFail("expected a root split")
        }
        XCTAssertEqual(root.id, outer)
        XCTAssertEqual(root.axis, .horizontal)
        assertRatios(root.ratios, [0.5, 0.5])
        guard case .pane(let left) = root.children[0], case .split(let stack) = root.children[1] else {
            return XCTFail("expected a nested stack")
        }
        XCTAssertEqual(left.tabID, a)
        XCTAssertEqual(stack.id, inner)
        XCTAssertEqual(stack.axis, .vertical)
        XCTAssertEqual(stack.children.map(\.tabID), [b, c])
        assertRatios(stack.ratios, [0.5, 0.5])
    }

    func testAddingAnExistingTabIsANoOp() {
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal)
        XCTAssertEqual(layout.adding(tabID: a, beside: b, axis: .vertical), layout)
        XCTAssertEqual(layout.adding(tabID: b, beside: b, axis: .horizontal), layout)
    }

    func testRemoveKeepsASplitAndRepairsRatios() {
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .vertical)
            .adding(tabID: c, beside: b, axis: .vertical)
            .focusing(a)
        let removed = layout.removing(tabID: b)
        XCTAssertEqual(removed?.tabIDs(), [a, c])
        XCTAssertEqual(removed?.focusedTabID, a)
        assertRatios(removed?.rootSplit?.ratios ?? [], [2.0 / 3.0, 1.0 / 3.0])
        XCTAssertEqual(layout.removing(tabID: d)?.tabIDs(), layout.tabIDs())
    }

    func testRemoveLastPaneCollapsesTheSplit() {
        let pair = TileLayout.split(anchor: a, newTab: b, axis: .horizontal)
        XCTAssertNil(pair.removing(tabID: b))
        XCTAssertNil(pair.removing(tabID: a))
        XCTAssertEqual(pair.focus(afterRemoving: b), a)
        XCTAssertEqual(pair.focus(afterRemoving: a), b)
        let trio = pair.adding(tabID: c, beside: b, axis: .horizontal)
        XCTAssertNotNil(trio.removing(tabID: c))
        XCTAssertNil(trio.removing(tabID: a)?.removing(tabID: b))
    }

    func testFocusAfterRemoveFollowsReadingOrder() {
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal)
            .adding(tabID: c, beside: b, axis: .horizontal)
            .focusing(b)
        XCTAssertEqual(layout.tabIDs(), [a, b, c])
        XCTAssertEqual(layout.focus(afterRemoving: b), c)
        XCTAssertEqual(layout.focusing(c).focus(afterRemoving: c), b)
        XCTAssertEqual(layout.focusing(a).focus(afterRemoving: a), b)
        XCTAssertEqual(layout.removing(tabID: b)?.focusedTabID, c)
        XCTAssertEqual(layout.focusing(c).removing(tabID: c)?.focusedTabID, b)
    }

    func testMovingOntoTheLeftOrUpEdgeLandsBeforeTheAnchor() {
        let columns = TileLayout.arranged(.twoColumns, tabs: [a, b], focused: a)!
        XCTAssertEqual(columns.moving(tabID: b, beside: a, edge: .left).tabIDs(), [b, a])
        XCTAssertEqual(columns.moving(tabID: a, beside: b, edge: .right).tabIDs(), [b, a])
        XCTAssertEqual(columns.moving(tabID: b, beside: a, edge: .right).tabIDs(), [a, b])

        let rows = TileLayout.arranged(.twoRows, tabs: [a, b], focused: a)!
        XCTAssertEqual(rows.moving(tabID: b, beside: a, edge: .up).tabIDs(), [b, a])
        XCTAssertEqual(rows.moving(tabID: a, beside: b, edge: .down).tabIDs(), [b, a])

        let three = TileLayout.arranged(.threeColumns, tabs: [a, b, c], focused: a)!
        let beforeAnchor = three.moving(tabID: c, beside: a, edge: .left).canonicalized()
        XCTAssertEqual(beforeAnchor.tabIDs(), [c, a, b])
        XCTAssertEqual(beforeAnchor.focusedTabID, a)
        XCTAssertEqual(three.moving(tabID: a, beside: c, edge: .right).tabIDs(), [b, c, a])
    }

    func testMoveReparentsAPane() {
        let sideways = TileLayout.split(anchor: a, newTab: b, axis: .horizontal)
        let stacked = sideways.moving(tabID: b, beside: a, axis: .vertical)
        XCTAssertEqual(stacked.tabIDs(), [a, b])
        XCTAssertEqual(stacked.rootSplit?.axis, .vertical)
        XCTAssertEqual(stacked.focusedTabID, b)

        let trio = sideways.adding(tabID: c, beside: b, axis: .horizontal).focusing(a)
        let moved = trio.moving(tabID: c, beside: a, axis: .horizontal)
        XCTAssertEqual(moved.tabIDs(), [a, c, b])
        XCTAssertEqual(moved.focusedTabID, a)
        XCTAssertEqual(trio.moving(tabID: a, beside: a, axis: .vertical).tabIDs(), trio.tabIDs())
    }

    func testResizeClampsTheDividerPairAndLeavesTheRest() {
        let splitID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal, splitID: splitID)
            .adding(tabID: c, beside: b, axis: .horizontal)
        assertRatios(layout.rootSplit?.ratios ?? [], [0.5, 0.25, 0.25])

        let widened = layout.resizing(splitID: splitID, divider: 0, proposedRatio: 0.4, length: 1000)
        assertRatios(widened.rootSplit?.ratios ?? [], [0.4, 0.35, 0.25])

        let floored = layout.resizing(splitID: splitID, divider: 1, proposedRatio: 0.01, length: 1000)
        assertRatios(floored.rootSplit?.ratios ?? [], [0.5, 0.2, 0.3])

        let untouched = layout.resizing(splitID: UUID(), divider: 0, proposedRatio: 0.1, length: 1000)
        assertRatios(untouched.rootSplit?.ratios ?? [], [0.5, 0.25, 0.25])
    }

    func testClampRatiosHonorsMinimumPaneSize() {
        assertRatios(TileLayout.clampRatios([0.05, 0.95], length: 1000, minimum: 200), [0.2, 0.8])
        assertRatios(TileLayout.clampRatios([0.05, 0.15, 0.80], length: 1000, minimum: 200), [0.2, 0.2, 0.6])
        assertRatios(TileLayout.clampRatios([0.5, 0.02, 0.48], length: 1000, minimum: 200), [
            0.5 / 0.98 * 0.8,
            0.2,
            0.48 / 0.98 * 0.8
        ])
        assertRatios(TileLayout.clampRatios([0.2, 0.2, 0.6], length: 500, minimum: 200), [
            1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0
        ])
        assertRatios(TileLayout.clampRatios([0.5, 0.5], length: 0, minimum: 200), [0.5, 0.5])
        let pair = TileLayout.resizeDivider(
            ratios: [0.2, 0.5, 0.3],
            divider: 0,
            proposedRatio: 0.9,
            length: 1000,
            minimum: 200
        )
        assertRatios(pair, [0.5, 0.2, 0.3])
    }

    func testEqualizeOneSplitOrTheWholeTree() {
        let inner = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal)
            .adding(tabID: c, beside: b, axis: .vertical, splitID: inner)
        guard let rootChildren = layout.rootSplit?.children,
              rootChildren.count == 2,
              case .split(let nested) = rootChildren[1] else {
            return XCTFail("expected a nested split")
        }
        let skewed = TileLayout(
            root: .split(TileSplit(
                id: layout.rootSplit?.id ?? UUID(),
                axis: .horizontal,
                children: [
                    layout.rootSplit?.children[0] ?? .pane(TilePane(tabID: a)),
                    .split(TileSplit(id: inner, axis: .vertical, children: nested.children, ratios: [0.2, 0.8]))
                ],
                ratios: [0.7, 0.3]
            )),
            focusedTabID: a
        )
        let onlyInner = skewed.equalizing(splitID: inner)
        assertRatios(onlyInner.rootSplit?.ratios ?? [], [0.7, 0.3])
        guard let innerChild = onlyInner.rootSplit?.children.dropFirst().first,
              case .split(let stack) = innerChild else {
            return XCTFail("expected the inner split")
        }
        assertRatios(stack.ratios, [0.5, 0.5])

        let all = skewed.equalized()
        assertRatios(all.rootSplit?.ratios ?? [], [0.5, 0.5])
        guard let equalChild = all.rootSplit?.children.dropFirst().first,
              case .split(let equalStack) = equalChild else {
            return XCTFail("expected the inner split")
        }
        assertRatios(equalStack.ratios, [0.5, 0.5])
    }

    func testNormalizeFlattensSameAxisAndCollapsesASingleChild() {
        let outer = UUID(uuidString: "10000000-0000-0000-0000-000000000006")!
        let inner = UUID(uuidString: "10000000-0000-0000-0000-000000000007")!
        let nested = TileNode.split(TileSplit(
            id: outer,
            axis: .horizontal,
            children: [
                .pane(TilePane(tabID: a)),
                .split(TileSplit(
                    id: inner,
                    axis: .horizontal,
                    children: [
                        .pane(TilePane(tabID: b)),
                        .pane(TilePane(tabID: c))
                    ],
                    ratios: [0.25, 0.75]
                ))
            ],
            ratios: [0.5, 0.5]
        ))
        guard case .split(let flat) = TileLayout.normalizedRoot(nested) else {
            return XCTFail("expected a flat split")
        }
        XCTAssertEqual(flat.id, outer)
        XCTAssertEqual(flat.axis, .horizontal)
        XCTAssertEqual(flat.children.map(\.tabID), [a, b, c])
        assertRatios(flat.ratios, [0.5, 0.125, 0.375])

        let single = TileNode.split(TileSplit(
            id: outer,
            axis: .vertical,
            children: [.pane(TilePane(tabID: a))],
            ratios: [1]
        ))
        XCTAssertEqual(TileLayout.normalizedRoot(single), .pane(TilePane(tabID: a)))

        let duplicate = TileNode.split(TileSplit(
            id: outer,
            axis: .horizontal,
            children: [.pane(TilePane(tabID: a)), .pane(TilePane(tabID: a))],
            ratios: [0.5, 0.5]
        ))
        XCTAssertEqual(TileLayout.normalizedRoot(duplicate), .pane(TilePane(tabID: a)))

        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal)
        XCTAssertEqual(layout.normalized(), layout)
    }

    func testFocusTraversalWrapsInReadingOrder() {
        let layout = TileLayout(
            root: .split(TileSplit(
                id: UUID(),
                axis: .horizontal,
                children: [
                    .pane(TilePane(tabID: a)),
                    .split(TileSplit(
                        id: UUID(),
                        axis: .vertical,
                        children: [
                            .pane(TilePane(tabID: b)),
                            .pane(TilePane(tabID: c))
                        ],
                        ratios: [0.5, 0.5]
                    )),
                    .pane(TilePane(tabID: d))
                ],
                ratios: [0.25, 0.5, 0.25]
            )),
            focusedTabID: c
        )
        XCTAssertEqual(layout.tabIDs(), [a, b, c, d])
        XCTAssertEqual(layout.focusingNext(forward: true).focusedTabID, d)
        XCTAssertEqual(layout.focusingNext(forward: false).focusedTabID, b)
        XCTAssertEqual(layout.focusing(d).focusingNext(forward: true).focusedTabID, a)
        XCTAssertEqual(layout.focusing(a).focusingNext(forward: false).focusedTabID, d)
        let walked = layout.tabIDs().reduce(layout.focusing(a)) { partial, _ in
            partial.focusingNext(forward: true)
        }
        XCTAssertEqual(walked.focusedTabID, a)
    }

    func testLayoutJSONRoundTrip() throws {
        let layout = TileLayout.split(
            anchor: a,
            newTab: b,
            axis: .vertical,
            splitID: UUID(uuidString: "10000000-0000-0000-0000-000000000008")!
        ).adding(
            tabID: c,
            beside: a,
            axis: .horizontal,
            splitID: UUID(uuidString: "10000000-0000-0000-0000-000000000009")!
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(TileLayout.self, from: data)
        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(decoded.tabIDs(), [a, c, b])
        XCTAssertEqual(decoded.focusedTabID, c)
    }

    func testSessionSnapshotRoundTripAndDropsInvalidIndexes() {
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal)
            .adding(tabID: c, beside: b, axis: .vertical)
            .focusing(b)
        let ids = [a, b, c]
        let snapshot = layout.sessionSnapshot { ids.firstIndex(of: $0) }
        let restored = snapshot.flatMap { TileLayout.restored($0) { index in
            ids.indices.contains(index) ? ids[index] : nil
        } }
        XCTAssertEqual(restored?.tabIDs(), [a, b, c])
        XCTAssertEqual(restored?.focusedTabID, b)
        assertRatios(restored?.rootSplit?.ratios ?? [], layout.rootSplit?.ratios ?? [])
        guard let nestedChild = restored?.rootSplit?.children.dropFirst().first,
              case .split(let stack) = nestedChild else {
            return XCTFail("expected the nested stack")
        }
        XCTAssertEqual(stack.axis, .vertical)
        XCTAssertEqual(stack.children.map(\.tabID), [b, c])

        let broken = SessionTileSnapshot(
            focusedTabIndex: 40,
            root: .split(axis: .horizontal, ratios: [0.2, 0.3, 0.5], children: [
                .pane(tabIndex: 0),
                .pane(tabIndex: 9),
                .pane(tabIndex: 1)
            ])
        )
        let repaired = TileLayout.restored(broken) { index in
            ids.indices.contains(index) ? ids[index] : nil
        }
        XCTAssertEqual(repaired?.tabIDs(), [a, b])
        XCTAssertEqual(repaired?.focusedTabID, a)
        assertRatios(repaired?.rootSplit?.ratios ?? [], [0.2 / 0.7, 0.5 / 0.7])

        let onlyOne = SessionTileSnapshot(
            focusedTabIndex: 0,
            root: .split(axis: .vertical, ratios: [0.5, 0.5], children: [
                .pane(tabIndex: 0),
                .pane(tabIndex: -1)
            ])
        )
        XCTAssertNil(TileLayout.restored(onlyOne) { index in
            ids.indices.contains(index) ? ids[index] : nil
        })
        XCTAssertNil(layout.sessionSnapshot { _ in nil })
    }

    func testWindowSnapshotKeepsTileAndOmitsItWhenAbsent() throws {
        let tile = SessionTileSnapshot(
            focusedTabIndex: 1,
            root: .split(axis: .horizontal, ratios: [0.5, 0.5], children: [
                .pane(tabIndex: 0),
                .pane(tabIndex: 1)
            ])
        )
        let snapshot = SessionSnapshot(windows: [
            SessionWindowSnapshot(tabs: [
                SessionTabSnapshot(kind: .web, url: "https://example.com/a"),
                SessionTabSnapshot(kind: .terminal, terminalBookmarkID: b)
            ], selectedIndex: 1, tile: tile)
        ])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.windows[0].tile?.focusedTabIndex, 1)
        XCTAssertEqual(decoded.windows[0].tile?.root.paneCount, 2)

        let bare = SessionWindowSnapshot(tabs: [
            SessionTabSnapshot(kind: .web, url: "https://example.com")
        ], selectedIndex: 0)
        let bareData = try JSONEncoder().encode(bare)
        let object = try JSONSerialization.jsonObject(with: bareData) as? [String: Any]
        XCTAssertNil(object?["tile"])
        XCTAssertNil(try JSONDecoder().decode(SessionWindowSnapshot.self, from: bareData).tile)
    }

    func testArrangementsMatchTheirTrees() {
        let cases: [(TileArrangement, [UUID])] = [
            (.twoColumns, [a, b]),
            (.twoRows, [a, b]),
            (.threeColumns, [a, b, c]),
            (.onePlusTwo, [a, b, c]),
            (.grid, [a, b, c, d])
        ]
        for (arrangement, tabs) in cases {
            let layout = TileLayout.arranged(arrangement, tabs: tabs, focused: tabs[0])
            XCTAssertEqual(layout?.arrangement, arrangement)
            XCTAssertEqual(layout?.tabIDs(), tabs)
            XCTAssertEqual(layout?.tabIDs().count, arrangement.paneCount)
            XCTAssertEqual(layout?.canonicalized().tabIDs(), tabs)
        }
        XCTAssertEqual(TileArrangement.maximumPanes, 4)
        XCTAssertEqual(TileArrangement.minimumPanes, 2)
        XCTAssertEqual(TileLayout.minimumPaneWidth, 320)
        XCTAssertEqual(TileLayout.minimumPaneHeight, 200)
    }

    func testMixedLayoutTerminalDevToolsAndWeb() {
        let layout = TileLayout.arranged(
            .threeColumns,
            tabs: [a, b, c],
            kinds: [.terminal, .devtools, .web],
            focused: b
        )
        XCTAssertEqual(layout?.arrangement, .threeColumns)
        XCTAssertEqual(layout?.focusedTabID, b)
        XCTAssertEqual(layout?.panes().map(\.tabID), [a, b, c])
        XCTAssertEqual(layout?.panes().map(\.kind), [.terminal, .devtools, .web])
        let data = try? JSONEncoder().encode(layout)
        let decoded = data.flatMap { try? JSONDecoder().decode(TileLayout.self, from: $0) }
        XCTAssertEqual(decoded?.panes().map(\.kind), [.terminal, .devtools, .web])
    }

    func testOldPaneJSONWithoutKindDecodesAsWeb() throws {
        let splitID = "10000000-0000-0000-0000-00000000000A"
        let json = """
        {"focusedTabID":"\(a.uuidString)","root":{"type":"split","id":"\(splitID)","axis":"horizontal","ratios":[0.5,0.5],"children":[{"type":"pane","tabID":"\(a.uuidString)"},{"type":"pane","tabID":"\(b.uuidString)","kind":"devtools"}]}}
        """
        let decoded = try JSONDecoder().decode(TileLayout.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.panes().map(\.kind), [.web, .devtools])
        XCTAssertEqual(decoded.arrangement, .twoColumns)
    }

    func testFifthPaneIsRefused() {
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal)
            .adding(tabID: c, beside: b, axis: .horizontal)
            .adding(tabID: d, beside: c, axis: .horizontal)
        XCTAssertEqual(layout.tabIDs().count, 4)
        let extra = UUID(uuidString: "00000000-0000-0000-0000-00000000000E")!
        XCTAssertEqual(layout.adding(tabID: extra, beside: d, axis: .horizontal).tabIDs(), layout.tabIDs())
        XCTAssertNil(layout.expanded(adding: extra, beside: d, edge: .right))
    }

    func testExpandedLandsOnCanonicalLayouts() {
        let columns = TileLayout.arranged(.twoColumns, tabs: [a, b], focused: a)!
        let three = columns.expanded(adding: c, beside: a, edge: .right, kind: .terminal)
        XCTAssertEqual(three?.arrangement, .threeColumns)
        XCTAssertEqual(three?.tabIDs(), [a, c, b])
        XCTAssertEqual(three?.panes().first { $0.tabID == c }?.kind, .terminal)

        let stacked = columns.expanded(adding: c, beside: b, edge: .down)
        XCTAssertEqual(stacked?.arrangement, .onePlusTwo)
        XCTAssertEqual(stacked?.tabIDs(), [a, b, c])

        let rows = TileLayout.arranged(.twoRows, tabs: [a, b], focused: b)!
        XCTAssertEqual(rows.expanded(adding: c, beside: b, edge: .right)?.arrangement, .threeColumns)
        XCTAssertNil(rows.expanded(adding: c, beside: a, edge: .down))
        XCTAssertEqual(rows.expanded(adding: c, beside: b, edge: .down)?.arrangement, .onePlusTwo)

        let grid = three?.expanded(adding: d, beside: c, edge: .down)
        XCTAssertEqual(grid?.arrangement, .grid)
        XCTAssertNil(grid?.expanded(adding: UUID(), beside: a, edge: .right))
    }

    /// 1+2 cannot divide the leading pane. Split Below on that pane is refused.
    /// The other pane still stacks the new tab on its own side.
    func testSplitBelowTheLeadingPaneIsRefused() {
        let columns = TileLayout.arranged(.twoColumns, tabs: [a, b], focused: a)!
        XCTAssertNil(columns.expanded(adding: c, beside: a, edge: .down))
        XCTAssertNil(columns.expanded(adding: c, beside: a, edge: .up))
        let underRight = columns.expanded(adding: c, beside: b, edge: .down)
        XCTAssertEqual(underRight?.arrangement, .onePlusTwo)
        XCTAssertEqual(underRight?.tabIDs(), [a, b, c])
        let overRight = columns.expanded(adding: c, beside: b, edge: .up)
        XCTAssertEqual(overRight?.arrangement, .onePlusTwo)
        XCTAssertEqual(overRight?.tabIDs(), [a, c, b])

        let rows = TileLayout.arranged(.twoRows, tabs: [a, b], focused: a)!
        XCTAssertNil(rows.expanded(adding: c, beside: a, edge: .down))
        XCTAssertNil(rows.expanded(adding: c, beside: a, edge: .up))
        XCTAssertEqual(rows.expanded(adding: c, beside: b, edge: .down)?.tabIDs(), [a, b, c])
        XCTAssertEqual(rows.expanded(adding: c, beside: b, edge: .up)?.tabIDs(), [a, c, b])
    }

    func testConvertedKeepsFocusedTailAndFillsBlanks() {
        let grid = TileLayout.arranged(.grid, tabs: [a, b, c, d], focused: c)!
        let columns = grid.converted(to: .twoColumns)
        XCTAssertEqual(columns?.tabIDs(), [c, d])
        XCTAssertEqual(columns?.focusedTabID, c)

        let pair = TileLayout.arranged(.twoColumns, tabs: [a, b], focused: a)!
        let filled = pair.converted(to: .threeColumns, filling: [c])
        XCTAssertEqual(filled?.tabIDs(), [a, b, c])
        XCTAssertNil(pair.converted(to: .grid))
    }

    /// A shorter layout must keep the focused tab even when the tail after it is too short.
    func testConvertedKeepsFocusWhenTheTailIsShorterThanTheLayout() {
        let grid = TileLayout.arranged(.grid, tabs: [a, b, c, d], focused: d)!
        let columns = grid.converted(to: .twoColumns)
        XCTAssertEqual(columns?.tabIDs(), [c, d])
        XCTAssertEqual(columns?.focusedTabID, d)
        let three = grid.converted(to: .threeColumns)
        XCTAssertEqual(three?.tabIDs(), [b, c, d])
        XCTAssertEqual(three?.focusedTabID, d)

        let nearEnd = TileLayout.arranged(.grid, tabs: [a, b, c, d], focused: c)!
        let narrowed = nearEnd.converted(to: .threeColumns)
        XCTAssertEqual(narrowed?.tabIDs(), [b, c, d])
        XCTAssertEqual(narrowed?.focusedTabID, c)

        let side = TileLayout.arranged(.onePlusTwo, tabs: [a, b, c], focused: c)!
        let pair = side.converted(to: .twoColumns)
        XCTAssertEqual(pair?.tabIDs(), [b, c])
        XCTAssertEqual(pair?.focusedTabID, c)
    }

    func testReplacingKeepsTheSplitAndMovesFocus() {
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal).focusing(a)
        let replaced = layout.replacing(tabID: a, with: c, kind: .terminal)
        XCTAssertEqual(replaced.tabIDs(), [c, b])
        XCTAssertEqual(replaced.focusedTabID, c)
        XCTAssertEqual(replaced.panes().map(\.kind), [.terminal, .web])
        XCTAssertEqual(replaced.arrangement, .twoColumns)
        XCTAssertEqual(layout.replacing(tabID: a, with: b, kind: .devtools).tabIDs(), layout.tabIDs())
    }

    func testPruneDropsTabsThatLeftTheSession() {
        let layout = TileLayout.split(anchor: a, newTab: b, axis: .horizontal)
            .adding(tabID: c, beside: b, axis: .horizontal)
        XCTAssertEqual(layout.pruning(keeping: [a, c])?.tabIDs(), [a, c])
        XCTAssertNil(layout.pruning(keeping: [a]))
        XCTAssertEqual(layout.pruning(keeping: [a, b, c])?.tabIDs(), layout.tabIDs())
    }

    func testSwappingTwoPanesExchangesOccupantsAndKeepsRatios() {
        let splitID = UUID(uuidString: "10000000-0000-0000-0000-0000000000AA")!
        let layout = TileLayout(
            root: .split(TileSplit(
                id: splitID,
                axis: .horizontal,
                children: [
                    .pane(TilePane(tabID: a, kind: .web)),
                    .pane(TilePane(tabID: b, kind: .terminal))
                ],
                ratios: [0.7, 0.3]
            )),
            focusedTabID: a
        )
        let swapped = layout.swapping(a, b)
        XCTAssertEqual(swapped.tabIDs(), [b, a])
        XCTAssertEqual(swapped.focusedTabID, a)
        XCTAssertEqual(swapped.panes().map(\.kind), [.terminal, .web])
        XCTAssertEqual(swapped.rootSplit?.id, splitID)
        assertRatios(swapped.rootSplit?.ratios ?? [], [0.7, 0.3])
        XCTAssertEqual(swapped.arrangement, .twoColumns)
        let frames = swapped.paneFrames()
        XCTAssertEqual(frames.map(\.tabID), [b, a])
        XCTAssertEqual(frames[0].width, layout.paneFrames()[0].width, accuracy: 1e-12)
        XCTAssertEqual(frames[1].width, layout.paneFrames()[1].width, accuracy: 1e-12)
    }

    func testSwappingCenterWithLeftInThreeColumns() {
        let layout = TileLayout.arranged(.threeColumns, tabs: [a, b, c], focused: b)!
        let swapped = layout.swapping(b, a)
        XCTAssertEqual(swapped.tabIDs(), [b, a, c])
        XCTAssertEqual(swapped.focusedTabID, b)
        XCTAssertEqual(swapped.arrangement, .threeColumns)
        assertRatios(swapped.rootSplit?.ratios ?? [], [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0])
        let order = TileStripOrder.placingMembers(
            session: [a, b, c],
            focused: b,
            membersInOrder: swapped.tabIDs()
        )
        XCTAssertEqual(order, [b, a, c])
        XCTAssertEqual(TileStripGroup.memberSpan(session: order, members: Set(swapped.tabIDs())), 0...2)
        let withOthers = TileStripOrder.placingMembers(
            session: [d, a, b, c],
            focused: b,
            membersInOrder: swapped.tabIDs()
        )
        XCTAssertEqual(withOthers, [d, b, a, c])
        XCTAssertEqual(TileStripGroup.memberSpan(session: withOthers, members: Set(swapped.tabIDs())), 1...3)
    }

    func testSwappingNestedOnePlusTwoKeepsShape() {
        let layout = TileLayout.arranged(.onePlusTwo, tabs: [a, b, c], focused: a)!
        let swapped = layout.swapping(a, c)
        XCTAssertEqual(swapped.tabIDs(), [c, b, a])
        XCTAssertEqual(swapped.focusedTabID, a)
        XCTAssertEqual(swapped.arrangement, .onePlusTwo)
        assertRatios(swapped.rootSplit?.ratios ?? [], layout.rootSplit?.ratios ?? [])
        guard case .split(let nested) = swapped.rootSplit?.children[1] else {
            return XCTFail("expected the stacked right column")
        }
        guard case .split(let original) = layout.rootSplit?.children[1] else {
            return XCTFail("expected the original stack")
        }
        XCTAssertEqual(nested.id, original.id)
        assertRatios(nested.ratios, original.ratios)
        XCTAssertEqual(nested.children.map(\.tabID), [b, a])
    }

    func testSwappingGridAndMixedKinds() {
        let layout = TileLayout.arranged(
            .grid,
            tabs: [a, b, c, d],
            kinds: [.web, .terminal, .devtools, .web],
            focused: a
        )!
        let swapped = layout.swapping(a, d)
        XCTAssertEqual(swapped.tabIDs(), [d, b, c, a])
        XCTAssertEqual(swapped.panes().map(\.kind), [.web, .terminal, .devtools, .web])
        XCTAssertEqual(swapped.arrangement, .grid)
        XCTAssertEqual(swapped.focusedTabID, a)

        let mixed = TileLayout.arranged(
            .threeColumns,
            tabs: [a, b, c],
            kinds: [.terminal, .devtools, .web],
            focused: b
        )!
        let crossed = mixed.swapping(a, c)
        XCTAssertEqual(crossed.tabIDs(), [c, b, a])
        XCTAssertEqual(crossed.panes().map(\.kind), [.web, .devtools, .terminal])
        XCTAssertEqual(crossed.focusedTabID, b)
    }

    func testSessionSnapshotAfterSwapKeepsOccupants() {
        let layout = TileLayout.arranged(.threeColumns, tabs: [a, b, c], focused: b)!
        let swapped = layout.swapping(b, a)
        let ids = swapped.tabIDs()
        let snapshot = swapped.sessionSnapshot { ids.firstIndex(of: $0) }
        let restored = snapshot.flatMap { TileLayout.restored($0) { index in
            ids.indices.contains(index) ? ids[index] : nil
        } }
        XCTAssertEqual(restored?.tabIDs(), [b, a, c])
        XCTAssertEqual(restored?.focusedTabID, b)
        XCTAssertEqual(restored?.arrangement, .threeColumns)
    }

    func testSwappingSelfOrMissingIdIsANoOp() {
        let layout = TileLayout.arranged(.twoColumns, tabs: [a, b], focused: a)!
        XCTAssertEqual(layout.swapping(a, a), layout)
        XCTAssertEqual(layout.swapping(a, d), layout)
        XCTAssertEqual(layout.swapping(d, a), layout)
        XCTAssertEqual(layout.swapping(d, c), layout)
        XCTAssertEqual(layout.exchanging(a, with: a), layout)
    }

    func testNeighborSwapAndSpokenPlace() {
        let columns = TileLayout.arranged(.twoColumns, tabs: [a, b], focused: a)!
        XCTAssertEqual(columns.neighbor(of: a, toward: .right), b)
        XCTAssertNil(columns.neighbor(of: a, toward: .left))
        XCTAssertEqual(columns.spokenPlace(of: a), "left pane")
        XCTAssertEqual(columns.spokenPlace(of: b), "right pane")
        let swapped = columns.swapping(toward: .right)
        XCTAssertEqual(swapped.tabIDs(), [b, a])
        XCTAssertEqual(swapped.focusedTabID, a)
        XCTAssertEqual(swapped.swapping(toward: .up).tabIDs(), swapped.tabIDs())

        let side = TileLayout.arranged(.onePlusTwo, tabs: [a, b, c], focused: a)!
        XCTAssertEqual(side.neighbor(of: a, toward: .right), b)
        XCTAssertEqual(side.neighbor(of: b, toward: .down), c)
        XCTAssertEqual(side.neighbor(of: b, toward: .left), a)
        XCTAssertEqual(side.neighbor(of: c, toward: .up), b)

        let grid = TileLayout.arranged(.grid, tabs: [a, b, c, d], focused: a)!
        XCTAssertEqual(grid.neighbor(of: a, toward: .right), b)
        XCTAssertEqual(grid.neighbor(of: a, toward: .down), c)
        XCTAssertEqual(grid.neighbor(of: d, toward: .left), c)
        XCTAssertEqual(grid.neighbor(of: d, toward: .up), b)
        XCTAssertEqual(grid.spokenPlace(of: b), "top right pane")
    }

    func testSnapFractionUsesEightPoints() {
        let exact = TileLayout.snapFraction(0.5, length: 1000)
        XCTAssertTrue(exact.snapped)
        XCTAssertEqual(exact.fraction, 0.5, accuracy: 1e-12)
        let near = TileLayout.snapFraction(0.5 + 7.0 / 1000.0, length: 1000)
        XCTAssertTrue(near.snapped)
        XCTAssertEqual(near.fraction, 0.5, accuracy: 1e-12)
        let far = TileLayout.snapFraction(0.5 + 20.0 / 1000.0, length: 1000)
        XCTAssertFalse(far.snapped)
        XCTAssertEqual(far.fraction, 0.52, accuracy: 1e-12)
        let third = TileLayout.snapFraction(1.0 / 3.0 + 0.002, length: 900)
        XCTAssertEqual(third.fraction, 1.0 / 3.0, accuracy: 1e-12)
        let neighbor = TileLayout.snapFraction(0.4, length: 1000, extraTargets: [0.405])
        XCTAssertEqual(neighbor.fraction, 0.405, accuracy: 1e-12)
        XCTAssertTrue(neighbor.snapped)
    }

    func testStripOrderPlacesMembersAfterTheFocusedTab() {
        // This used to expect [a, b, c, d]. That was focused-first: `b` led and the
        // other members followed, which reversed tile reading order [c, b, d].
        let result = TileStripOrder.placingMembers(session: [a, c, b, d], focused: b, membersInOrder: [c, b, d])
        XCTAssertEqual(result, [a, c, b, d])
        let already = TileStripOrder.placingMembers(session: [a, b], focused: a, membersInOrder: [a, b])
        XCTAssertEqual(already, [a, b])
        // A non-member that sat between panes stays outside the group, in its relative place.
        let between = TileStripOrder.placingMembers(session: [b, a, c], focused: c, membersInOrder: [b, c])
        XCTAssertEqual(between, [b, c, a])
    }

    func testSplitFromSecondOfTwoKeepsLeftPaneFirst() {
        // Tabs [a, b], b active. Split right appends c. Panes are b | c, focus c.
        let order = TileStripOrder.placingMembers(session: [a, b, c], focused: c, membersInOrder: [b, c])
        XCTAssertEqual(order, [a, b, c])
        XCTAssertEqual(TileStripGroup.memberSpan(session: order, members: [b, c]), 1...2)
    }

    func testSplitFromFirstOfThreeKeepsReadingOrder() {
        // Tabs [a, b, c], a active. The new tab is inserted after a, then aligned.
        // Panes are a | d. b and c stay after the group, in their old order.
        let order = TileStripOrder.placingMembers(session: [a, d, b, c], focused: d, membersInOrder: [a, d])
        XCTAssertEqual(order, [a, d, b, c])
        XCTAssertEqual(TileStripGroup.memberSpan(session: order, members: [a, d]), 0...1)
    }

    func testUnsplitKeepsTileReadingOrder() {
        // The reversed strip [a, c, b] is what focused-first produced for panes b | c.
        // Unsplit orders once more before the group dissolves, and must not leave c first.
        let order = TileStripOrder.placingMembers(session: [a, c, b], focused: c, membersInOrder: [b, c])
        XCTAssertEqual(order, [a, b, c])
        XCTAssertNil(TileStripGroup.memberSpan(session: order, members: []))
        let already = TileStripOrder.placingMembers(session: [a, b, c], focused: c, membersInOrder: [b, c])
        XCTAssertEqual(already, [a, b, c])
    }

    func testNarrowWindowStacksColumns() {
        let three = TileLayout.arranged(.threeColumns, tabs: [a, b, c])!
        XCTAssertTrue(TileDisplay.needsRowFallback(node: three.root, contentWidth: 900))
        XCTAssertFalse(TileDisplay.needsRowFallback(node: three.root, contentWidth: 976))
        let rows = TileLayout.arranged(.twoRows, tabs: [a, b])!
        XCTAssertFalse(TileDisplay.needsRowFallback(node: rows.root, contentWidth: 200))
        XCTAssertEqual(TileDisplay.columnCount(in: three.root), 3)
        XCTAssertEqual(TileDisplay.minimumContentWidth(paneCount: 4), 4 * 320 + 3 * 8, accuracy: 0.001)
        XCTAssertEqual(TileDisplay.requiredContentMinWidth(paneCount: 2, splitVisible: true), 980, accuracy: 0.001)
        XCTAssertEqual(TileDisplay.requiredContentMinWidth(paneCount: 3, splitVisible: true), 980, accuracy: 0.001)
        XCTAssertEqual(
            TileDisplay.requiredContentMinWidth(paneCount: 4, splitVisible: true),
            4 * 320 + 3 * 8,
            accuracy: 0.001
        )
        XCTAssertEqual(TileDisplay.requiredContentMinWidth(paneCount: 4, splitVisible: false), 980, accuracy: 0.001)
        XCTAssertEqual(TileDisplay.requiredContentMinWidth(paneCount: 1, splitVisible: true), 980, accuracy: 0.001)
        let stacked = three.stackedDisplay(splitID: UUID())
        XCTAssertEqual(stacked.tabIDs(), [a, b, c])
        XCTAssertEqual(stacked.rootSplit?.axis, .vertical)
    }

    func testPaneHealthArchiveKeepsHistoryPerTab() {
        struct Memory: Equatable, Sendable {
            var host: String
            var samples: Int
        }
        var archive = PaneHealthArchive<Memory>()
        archive.remember(Memory(host: "example.com", samples: 4), for: a)
        archive.remember(Memory(host: "other.test", samples: 2), for: b)
        XCTAssertEqual(archive.record(for: a)?.samples, 4)
        XCTAssertEqual(archive.count, 2)
        archive.prune(keeping: [b])
        XCTAssertNil(archive.record(for: a))
        XCTAssertEqual(archive.record(for: b)?.host, "other.test")
        XCTAssertEqual(PaneProbeCadence.focused, HealthLimits.probeInterval)
        XCTAssertEqual(PaneProbeCadence.visibleUnfocused, 6)
    }

    private func assertRatios(_ values: [Double], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(values.count, expected.count, file: file, line: line)
        for (value, target) in zip(values, expected) {
            XCTAssertEqual(value, target, accuracy: 1e-9, file: file, line: line)
        }
    }
}

private extension TileLayout {
    var rootSplit: TileSplit? {
        if case .split(let split) = root { return split }
        return nil
    }
}

private extension TileNode {
    var tabID: UUID? {
        if case .pane(let pane) = self { return pane.tabID }
        return nil
    }
}
