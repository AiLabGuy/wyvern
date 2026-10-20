// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit

/// What a pane hosts. Web, terminal, and a future DevTools tab all use this.
/// The canvas does not switch on the kind.
@MainActor
protocol TilePaneContent: AnyObject {
    var tileView: NSView { get }
    var tileTitle: String { get }
    var tileFocusTarget: NSView? { get }
    var tileKind: TabKind { get }
}

enum TilePanePillStyle {
    case standard
    case devtools
}

/// One pane's hosted view plus the insets and page fill around it.
struct TilePanePresentation {
    var content: (any TilePaneContent)?
    var insets: NSEdgeInsets
    var fill: TilePaneFill
    var pill: TilePanePillStyle = .standard
}

/// Adapts an existing view to `TilePaneContent` without a per-type branch in the canvas.
@MainActor
final class TilePaneHost: TilePaneContent {
    let tileView: NSView
    let tileTitle: String
    let tileFocusTarget: NSView?
    let tileKind: TabKind

    init(view: NSView, title: String, focus: NSView?, kind: TabKind) {
        tileView = view
        tileTitle = title
        tileFocusTarget = focus
        tileKind = kind
    }
}

enum TilePaneFill {
    case page
    case terminal
}

/// Drop preview drawn over the page. Clicks pass through to the page.
@MainActor
final class TileDropPreview: NSView {
    var caption: String = "" {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        Theme.accent.withAlphaComponent(0.12).setFill()
        path.fill()
        Theme.accent.setStroke()
        path.lineWidth = 2
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.stroke()
        guard !caption.isEmpty else { return }
        let text = NSAttributedString(string: caption, attributes: [
            .font: Theme.font(size: 12, weight: .medium),
            .foregroundColor: Theme.text
        ])
        let size = text.size()
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        text.draw(at: origin)
    }
}

/// Custom split layout instead of `NSSplitView`. The view is not flipped, so web and terminal
/// views stay upright. The first child of a vertical split is the top one.
@MainActor
final class TileCanvasView: NSView {
    var onFocus: ((UUID) -> Void)?
    var onResize: ((UUID, Int, Double, Double, Bool) -> Void)?
    var onEqualize: ((UUID) -> Void)?
    var onAppearance: (() -> Void)?
    var onMakeMain: ((UUID) -> Void)?
    var onClosePane: ((UUID) -> Void)?
    var devToolsMoveMenu: ((UUID) -> NSMenu?)?
    var onPopOut: ((UUID) -> Void)?
    var onDevToolsOverflow: ((UUID, NSView) -> Void)?
    /// The tree was rebuilt and hosted views were detached. The window restores key focus.
    var onStructureChange: (() -> Void)?
    /// Pane-pill drag. Screen points. Press arms Esc cancel; changed/ended drive the drop.
    var onPaneDragPress: ((UUID) -> Void)?
    var onPaneDragChanged: ((UUID, NSPoint) -> Void)?
    var onPaneDragEnded: ((UUID, NSPoint) -> Void)?

    private(set) var model: TileLayout?
    private var content: ((UUID, Bool) -> TilePanePresentation?)?
    private var rootView: NSView?
    private var panes: [TilePaneView] = []
    private var splitViews: [TileSplitView] = []
    private var dividers: [TileDividerView] = []
    private var crossViews: [TileCrossView] = []
    private var builtSignature: String?
    private var monitor: Any?
    private var displayStacked = false
    private var fallbackLayout: TileLayout?
    private let fallbackSplitID = UUID()
    private var inLayout = false
    /// Set when the tree is rebuilt and hosted views are detached.
    private(set) var structureChanged = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Split View")
        setAccessibilityIdentifier("wyvern.tile.canvas")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            startMonitoring()
            window?.acceptsMouseMovedEvents = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearance?()
    }

    override func layout() {
        super.layout()
        guard !inLayout else { return }
        inLayout = true
        defer { inLayout = false }
        var rebuilt = false
        if let model {
            let wasStacked = displayStacked
            let displayed = layoutForDisplay(model)
            if displayStacked != wasStacked {
                rebuild(using: displayed)
                builtSignature = Self.signature(of: displayed.root) + (displayStacked ? ":stack" : "")
                structureChanged = true
                refreshContent()
                rebuilt = true
            }
        }
        guard let rootView else {
            if rebuilt {
                deliverStructureChangeIfNeeded()
            }
            return
        }
        rootView.frame = bounds
        relayoutSplits()
        placeCrosses()
        refreshPaneChrome()
        if rebuilt {
            deliverStructureChangeIfNeeded()
        }
    }

    /// One structure callback per turn. A second layout in the same turn must not re-enter it.
    /// The callback itself still runs now, so the window can see where keyboard focus is.
    private var layoutNotify = LayoutNotifyCoalescer()

    private func deliverStructureChangeIfNeeded() {
        guard onStructureChange != nil else { return }
        guard layoutNotify.request() else { return }
        onStructureChange?()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.layoutNotify.take()
            }
        }
    }

    func consumeStructureChange() -> Bool {
        let changed = structureChanged
        structureChanged = false
        return changed
    }

    /// Rebuilds the tree only when the split structure changes. Ratio and focus updates relayout.
    func show(layout: TileLayout?, content: ((UUID, Bool) -> TilePanePresentation?)?) {
        self.content = content
        model = layout
        guard let layout, layout.isSplit else {
            tearDown()
            return
        }
        let displayed = layoutForDisplay(layout)
        let signature = Self.signature(of: displayed.root) + (displayStacked ? ":stack" : "")
        if signature != builtSignature {
            structureChanged = true
            rebuild(using: displayed)
            builtSignature = signature
        } else {
            rebindPaneIDs(from: displayed)
        }
        refreshContent()
        // Layout the canvas once. Marking it dirty again from inside `layout()` loops forever.
        if inLayout {
            relayoutSplits()
        } else {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    /// Pane frames in this view's coordinates. Drag-to-edge uses them.
    func paneFrames() -> [(UUID, NSRect)] {
        panes.map { pane in
            (pane.tabID, pane.convert(pane.bounds, to: self))
        }
    }

    func refreshPaneChrome() {
        for pane in panes {
            pane.refreshChrome()
        }
    }

    func relayoutSplits() {
        for split in splitViews {
            split.needsLayout = true
            split.layoutSubtreeIfNeeded()
        }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.focusPane(on: event)
            }
            return event
        }
    }

    private func stopMonitoring() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// Clicks land in the web view or terminal. The monitor records which pane that was
    /// without eating the event, so the page still receives it.
    private func focusPane(on event: NSEvent) {
        guard !isHidden, let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        guard let hit = hitTest(point) else { return }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is TileDividerView || current is TileCrossView { return }
            if let pane = current as? TilePaneView {
                guard pane.tabID != model?.focusedTabID else { return }
                onFocus?(pane.tabID)
                return
            }
            view = current.superview
        }
    }

    private func refreshContent() {
        guard let model else { return }
        let count = panes.count
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        setAccessibilityLabel("Split View, \(count) panes")
        for (offset, pane) in panes.enumerated() {
            let focused = pane.tabID == model.focusedTabID
            let presentation = content?(pane.tabID, focused)
            pane.install(presentation)
            pane.showsFocus = focused && model.isSplit
            pane.showsInactiveRing = contrast && !focused && model.isSplit
            let title = presentation?.content?.tileTitle ?? "Pane"
            let kind = presentation?.content?.tileKind ?? .web
            if kind == .devtools {
                pane.accessibilityTitle = title
            } else {
                pane.accessibilityTitle = "Pane \(offset + 1) of \(count), \(title)"
            }
            pane.setAccessibilityIdentifier("wyvern.tile.pane.\(offset)")
            pane.setAccessibilityValue(kind.rawValue)
            pane.setPillStyle(presentation?.pill ?? .standard)
            pane.setAccessibilityFocused(focused)
        }
    }

    private func tearDown() {
        structureChanged = builtSignature != nil
        for pane in panes {
            pane.clearHost()
        }
        panes.removeAll()
        splitViews.removeAll()
        dividers.removeAll()
        for cross in crossViews {
            cross.removeFromSuperview()
        }
        crossViews.removeAll()
        rootView?.removeFromSuperview()
        rootView = nil
        builtSignature = nil
        fallbackLayout = nil
        displayStacked = false
        model = nil
    }

    private func rebuild(using layout: TileLayout) {
        for pane in panes {
            pane.clearHost()
        }
        panes.removeAll()
        splitViews.removeAll()
        dividers.removeAll()
        for cross in crossViews {
            cross.removeFromSuperview()
        }
        crossViews.removeAll()
        rootView?.removeFromSuperview()
        let root = makeNode(layout.root)
        root.translatesAutoresizingMaskIntoConstraints = true
        root.autoresizingMask = [.width, .height]
        addSubview(root)
        rootView = root
    }

    private func layoutForDisplay(_ layout: TileLayout) -> TileLayout {
        let stacked = bounds.width > 1 && TileDisplay.needsRowFallback(
            node: layout.root,
            contentWidth: Double(bounds.width),
            paneMinWidth: Double(MonoMetrics.paneMinWidth),
            divider: Double(MonoMetrics.dividerHit)
        )
        displayStacked = stacked
        guard stacked else {
            fallbackLayout = nil
            return layout
        }
        if fallbackLayout == nil || fallbackLayout?.tabIDs() != layout.tabIDs() {
            fallbackLayout = layout.stackedDisplay(splitID: fallbackSplitID)
        }
        if let fallback = fallbackLayout, fallback.focusedTabID != layout.focusedTabID {
            fallbackLayout = fallback.focusing(layout.focusedTabID)
        }
        return fallbackLayout ?? layout
    }

    private func makeNode(_ node: TileNode) -> NSView {
        switch node {
        case .pane(let pane):
            let view = TilePaneView(tabID: pane.tabID)
            view.canvas = self
            view.translatesAutoresizingMaskIntoConstraints = true
            panes.append(view)
            return view
        case .split(let split):
            let view = TileSplitView(splitID: split.id, axis: split.axis)
            view.canvas = self
            view.translatesAutoresizingMaskIntoConstraints = true
            splitViews.append(view)
            var children: [NSView] = []
            children.reserveCapacity(split.children.count)
            for child in split.children {
                children.append(makeNode(child))
            }
            var made: [TileDividerView] = []
            if children.count > 1 {
                for index in 0..<(children.count - 1) {
                    let divider = TileDividerView()
                    divider.axis = split.axis
                    divider.index = index
                    divider.splitID = split.id
                    divider.translatesAutoresizingMaskIntoConstraints = true
                    divider.onDrag = { [weak self, weak view, weak divider] point, commit in
                        guard let self, let view, let divider else { return }
                        guard let proposed = view.proposed(
                            divider: index,
                            windowPoint: point,
                            grabOffset: divider.grabOffset
                        ) else { return }
                        divider.noteSnap(proposed.snapped)
                        self.commitResize(
                            splitID: split.id,
                            divider: index,
                            ratio: proposed.ratio,
                            length: proposed.length,
                            commit: commit
                        )
                    }
                    divider.onEqualize = { [weak self] in
                        self?.commitEqualize(splitID: split.id)
                    }
                    divider.onNudge = { [weak self, weak view] points in
                        guard let self, let view else { return }
                        guard let proposed = view.nudge(divider: index, points: points) else { return }
                        self.commitResize(
                            splitID: split.id,
                            divider: index,
                            ratio: proposed.ratio,
                            length: proposed.length,
                            commit: true
                        )
                    }
                    made.append(divider)
                    dividers.append(divider)
                }
            }
            view.nodeViews = children
            view.dividers = made
            for child in children {
                view.addSubview(child)
            }
            for divider in made {
                view.addSubview(divider)
            }
            return view
        }
    }

    private func commitResize(splitID: UUID, divider: Int, ratio: Double, length: Double, commit: Bool) {
        if displayStacked, var fallback = fallbackLayout {
            fallbackLayout = fallback.resizing(
                splitID: splitID,
                divider: divider,
                proposedRatio: ratio,
                length: length,
                minimum: TileLayout.minimumPaneHeight
            )
            relayoutSplits()
            return
        }
        onResize?(splitID, divider, ratio, length, commit)
    }

    private func commitEqualize(splitID: UUID) {
        if displayStacked, let fallback = fallbackLayout {
            fallbackLayout = fallback.equalizing(splitID: splitID)
            relayoutSplits()
            return
        }
        onEqualize?(splitID)
    }

    private func placeCrosses() {
        var hits: [(NSRect, TileDividerView, TileDividerView)] = []
        let verticalBars = dividers.filter { $0.axis == .horizontal }
        let horizontalBars = dividers.filter { $0.axis == .vertical }
        let side: CGFloat = 12
        for vertical in verticalBars {
            let verticalFrame = vertical.convert(vertical.bounds, to: self)
            for horizontal in horizontalBars {
                let horizontalFrame = horizontal.convert(horizontal.bounds, to: self)
                let hit = verticalFrame.intersection(horizontalFrame)
                guard !hit.isNull, hit.width > 0.5, hit.height > 0.5 else { continue }
                hits.append((
                    NSRect(x: hit.midX - side / 2, y: hit.midY - side / 2, width: side, height: side),
                    vertical,
                    horizontal
                ))
            }
        }
        // Moving an existing cross avoids adding and removing views on every layout pass.
        if hits.count == crossViews.count {
            for (hit, cross) in zip(hits, crossViews) {
                cross.frame = hit.0
            }
            return
        }
        for cross in crossViews {
            cross.removeFromSuperview()
        }
        crossViews.removeAll()
        for hit in hits {
            let cross = TileCrossView()
            cross.frame = hit.0
            let verticalDivider = hit.1
            let horizontalDivider = hit.2
            cross.onDrag = { point, commit in
                verticalDivider.grabOffset = 0
                horizontalDivider.grabOffset = 0
                verticalDivider.onDrag?(point, commit)
                horizontalDivider.onDrag?(point, commit)
            }
            addSubview(cross)
            crossViews.append(cross)
        }
    }

    fileprivate func dividerFractions(axis: TileAxis, except splitID: UUID) -> [Double] {
        let source = displayStacked ? fallbackLayout : model
        var targets: [Double] = []
        for split in splitViews where split.axis == axis && split.splitID != splitID {
            guard let ratios = source?.split(id: split.splitID)?.ratios else { continue }
            var sum = 0.0
            for (index, ratio) in ratios.enumerated() where index < ratios.count - 1 {
                sum += ratio
                targets.append(sum)
            }
        }
        return targets
    }

    fileprivate func displayedSplit(_ id: UUID) -> TileSplit? {
        let source = displayStacked ? fallbackLayout : model
        return source?.split(id: id)
    }

    /// Occupant-only updates keep each hosted view in its pane. Pane views move to the
    /// new slots so WKWebView is not removed and inserted again.
    private func rebindPaneIDs(from layout: TileLayout) {
        let ids = layout.tabIDs()
        guard ids.count == panes.count else { return }
        if panes.map(\.tabID) == ids { return }
        let byID = Dictionary(uniqueKeysWithValues: panes.map { ($0.tabID, $0) })
        guard ids.allSatisfy({ byID[$0] != nil }) else {
            for (pane, id) in zip(panes, ids) where pane.tabID != id {
                pane.tabID = id
            }
            return
        }
        let ordered = ids.map { byID[$0]! }
        let slots: [(TileSplitView, Int)] = panes.compactMap { pane in
            guard let parent = pane.superview as? TileSplitView,
                  let index = parent.nodeViews.firstIndex(where: { $0 === pane }) else {
                return nil
            }
            return (parent, index)
        }
        guard slots.count == ordered.count else {
            for (pane, id) in zip(panes, ids) where pane.tabID != id {
                pane.tabID = id
            }
            return
        }
        for (slot, pane) in zip(slots, ordered) {
            let (parent, index) = slot
            parent.nodeViews[index] = pane
            if pane.superview !== parent {
                if let divider = parent.dividers.first {
                    parent.addSubview(pane, positioned: .below, relativeTo: divider)
                } else {
                    parent.addSubview(pane)
                }
            }
        }
        panes = ordered
        relayoutSplits()
    }

    /// Structure only: split ids, axes, and child shape. Occupant (tab id) changes
    /// rebind existing pane views so hosted web views are not removed and re-added.
    private static func signature(of node: TileNode) -> String {
        switch node {
        case .pane:
            return "p"
        case .split(let split):
            let children = split.children.map { signature(of: $0) }.joined(separator: ",")
            return "s:" + split.id.uuidString + ":" + split.axis.rawValue + "[" + children + "]"
        }
    }
}

@MainActor
final class TileSplitView: NSView {
    let splitID: UUID
    let axis: TileAxis
    var nodeViews: [NSView] = []
    var dividers: [TileDividerView] = []
    weak var canvas: TileCanvasView?

    init(splitID: UUID, axis: TileAxis) {
        self.splitID = splitID
        self.axis = axis
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        positionChildren()
        for node in nodeViews {
            node.layoutSubtreeIfNeeded()
        }
    }

    func proposed(divider: Int, windowPoint: NSPoint, grabOffset: CGFloat) -> (ratio: Double, length: Double, snapped: Bool)? {
        guard let ratios = canvas?.displayedSplit(splitID)?.ratios else { return nil }
        guard ratios.indices.contains(divider), divider + 1 < ratios.count else { return nil }
        let local = convert(windowPoint, from: nil)
        let gap = MonoMetrics.dividerHit
        let minimum = axis == .horizontal ? TileLayout.minimumPaneWidth : TileLayout.minimumPaneHeight
        if axis == .horizontal {
            let content = max(bounds.width - gap * CGFloat(ratios.count - 1), 1)
            let shown = TileLayout.clampRatios(ratios, length: Double(content), minimum: minimum)
            let before = shown.prefix(divider).reduce(0, +)
            let centerX = local.x - grabOffset
            let contentX = centerX - CGFloat(divider) * gap - gap / 2
            return snappedShare(raw: Double(contentX / content) - before, before: before, length: Double(content))
        }
        let content = max(bounds.height - gap * CGFloat(ratios.count - 1), 1)
        let shown = TileLayout.clampRatios(ratios, length: Double(content), minimum: minimum)
        let before = shown.prefix(divider).reduce(0, +)
        let centerY = local.y - grabOffset
        let fromTop = bounds.height - centerY
        let contentY = fromTop - CGFloat(divider) * gap - gap / 2
        return snappedShare(raw: Double(contentY / content) - before, before: before, length: Double(content))
    }

    func nudge(divider: Int, points: CGFloat) -> (ratio: Double, length: Double)? {
        guard let ratios = canvas?.displayedSplit(splitID)?.ratios else { return nil }
        guard ratios.indices.contains(divider) else { return nil }
        let gap = MonoMetrics.dividerHit
        let minimum = axis == .horizontal ? TileLayout.minimumPaneWidth : TileLayout.minimumPaneHeight
        let content = axis == .horizontal
            ? max(bounds.width - gap * CGFloat(ratios.count - 1), 1)
            : max(bounds.height - gap * CGFloat(ratios.count - 1), 1)
        let shown = TileLayout.clampRatios(ratios, length: Double(content), minimum: minimum)
        let before = shown.prefix(divider).reduce(0, +)
        let fraction = before + shown[divider] + Double(points) / Double(content)
        let share = fraction - before
        return (share, Double(content))
    }

    private func snappedShare(raw: Double, before: Double, length: Double) -> (ratio: Double, length: Double, snapped: Bool) {
        let fraction = before + raw
        let extras = canvas?.dividerFractions(axis: axis, except: splitID) ?? []
        let snapped = TileLayout.snapFraction(
            fraction,
            length: length,
            tolerance: Double(MonoMetrics.snapTolerance),
            extraTargets: extras
        )
        return (snapped.fraction - before, length, snapped.snapped)
    }

    private func positionChildren() {
        guard let ratios = canvas?.displayedSplit(splitID)?.ratios else { return }
        let count = nodeViews.count
        guard count > 0, ratios.count == count else { return }
        let gap = MonoMetrics.dividerHit
        let gaps = gap * CGFloat(max(count - 1, 0))
        let minimum = axis == .horizontal ? TileLayout.minimumPaneWidth : TileLayout.minimumPaneHeight
        if axis == .horizontal {
            let content = max(bounds.width - gaps, 1)
            let shown = TileLayout.clampRatios(ratios, length: Double(content), minimum: minimum)
            var x: CGFloat = 0
            var covered = 0.0
            for index in 0..<count {
                let width = content * CGFloat(shown[index])
                nodeViews[index].frame = NSRect(x: x, y: 0, width: max(width, 0), height: bounds.height)
                x += width
                covered += shown[index]
                if index < dividers.count {
                    dividers[index].frame = NSRect(x: x, y: 0, width: gap, height: bounds.height)
                    let percent = Int((covered * 100).rounded())
                    dividers[index].setAccessibilityValue("\(percent)%")
                    x += gap
                }
            }
            return
        }
        let content = max(bounds.height - gaps, 1)
        let shown = TileLayout.clampRatios(ratios, length: Double(content), minimum: minimum)
        var y = bounds.height
        var covered = 0.0
        for index in 0..<count {
            let height = content * CGFloat(shown[index])
            y -= height
            nodeViews[index].frame = NSRect(x: 0, y: y, width: bounds.width, height: max(height, 0))
            covered += shown[index]
            if index < dividers.count {
                y -= gap
                dividers[index].frame = NSRect(x: 0, y: y, width: bounds.width, height: gap)
                let percent = Int((covered * 100).rounded())
                dividers[index].setAccessibilityValue("\(percent)%")
            }
        }
    }
}

@MainActor
final class TileDividerView: NSView {
    var axis: TileAxis = .horizontal {
        didSet { resetCursorRects() }
    }
    var index = 0
    var splitID = UUID()
    var grabOffset: CGFloat = 0
    var onDrag: ((NSPoint, Bool) -> Void)?
    var onEqualize: (() -> Void)?
    var onNudge: ((CGFloat) -> Void)?

    private var hovered = false
    private var dragging = false
    private var accentOpacity: CGFloat = 0
    private var accentTarget: CGFloat = 0
    private var fadeTimer: Timer?
    private var wasSnapped = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize panes")
        setAccessibilityIdentifier("wyvern.tile.divider")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        setAccent(visible: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        if !dragging {
            setAccent(visible: false)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if contrast {
            Theme.text.withAlphaComponent(0.4).setFill()
            fillBar(thickness: 2)
        } else {
            Theme.line.setFill()
            fillBar(thickness: MonoMetrics.dividerVisual)
        }
        if accentOpacity > 0.01 {
            Theme.accent.withAlphaComponent(accentOpacity).setFill()
            fillBar(thickness: 2)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onEqualize?()
            return
        }
        guard let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        grabOffset = axis == .horizontal ? local.x - bounds.midX : local.y - bounds.midY
        dragging = true
        wasSnapped = false
        setAccent(visible: true)
        while true {
            let next: NSEvent? = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            )
            guard let next else { break }
            let commit = next.type == .leftMouseUp
            onDrag?(next.locationInWindow, commit)
            if commit { break }
        }
        dragging = false
        setAccent(visible: hovered)
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 64 : 16
        switch event.keyCode {
        case 123 where axis == .horizontal:
            onNudge?(-step)
        case 124 where axis == .horizontal:
            onNudge?(step)
        case 126 where axis == .vertical:
            onNudge?(-step)
        case 125 where axis == .vertical:
            onNudge?(step)
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        onNudge?(16)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onNudge?(-16)
        return true
    }

    func noteSnap(_ snapped: Bool) {
        if snapped && !wasSnapped {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            accentOpacity = 1
            needsDisplay = true
            fadeTimer?.invalidate()
            let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setAccent(visible: self.hovered || self.dragging)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            fadeTimer = timer
        }
        wasSnapped = snapped
    }

    private func setAccent(visible: Bool) {
        accentTarget = visible ? 1 : 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            accentOpacity = accentTarget
            needsDisplay = true
            return
        }
        fadeTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let step: CGFloat = 1.0 / (0.12 * 60.0)
                if self.accentOpacity < self.accentTarget {
                    self.accentOpacity = min(self.accentTarget, self.accentOpacity + step)
                } else {
                    self.accentOpacity = max(self.accentTarget, self.accentOpacity - step)
                }
                self.needsDisplay = true
                if abs(self.accentOpacity - self.accentTarget) < 0.02 {
                    self.accentOpacity = self.accentTarget
                    timer.invalidate()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func fillBar(thickness: CGFloat) {
        if axis == .horizontal {
            NSRect(
                x: bounds.midX - thickness / 2,
                y: 0,
                width: thickness,
                height: bounds.height
            ).fill()
        } else {
            NSRect(
                x: 0,
                y: bounds.midY - thickness / 2,
                width: bounds.width,
                height: thickness
            ).fill()
        }
    }
}

/// 12×12 hit where a column divider crosses a row divider. Drags both.
@MainActor
final class TileCrossView: NSView {
    var onDrag: ((NSPoint, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: TileCursors.moveAll)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        while true {
            let next: NSEvent? = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            )
            guard let next else { return }
            let commit = next.type == .leftMouseUp
            onDrag?(next.locationInWindow, commit)
            if commit { return }
        }
    }
}

enum TileCursors {
    static let moveAll: NSCursor = {
        let side: CGFloat = 16
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath()
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: 8, y: 1.5))
            path.line(to: NSPoint(x: 8, y: 14.5))
            path.move(to: NSPoint(x: 1.5, y: 8))
            path.line(to: NSPoint(x: 14.5, y: 8))
            path.move(to: NSPoint(x: 8, y: 1.5))
            path.line(to: NSPoint(x: 6.2, y: 3.4))
            path.move(to: NSPoint(x: 8, y: 1.5))
            path.line(to: NSPoint(x: 9.8, y: 3.4))
            path.move(to: NSPoint(x: 8, y: 14.5))
            path.line(to: NSPoint(x: 6.2, y: 12.6))
            path.move(to: NSPoint(x: 8, y: 14.5))
            path.line(to: NSPoint(x: 9.8, y: 12.6))
            path.move(to: NSPoint(x: 1.5, y: 8))
            path.line(to: NSPoint(x: 3.4, y: 6.2))
            path.move(to: NSPoint(x: 1.5, y: 8))
            path.line(to: NSPoint(x: 3.4, y: 9.8))
            path.move(to: NSPoint(x: 14.5, y: 8))
            path.line(to: NSPoint(x: 12.6, y: 6.2))
            path.move(to: NSPoint(x: 14.5, y: 8))
            path.line(to: NSPoint(x: 12.6, y: 9.8))
            NSColor.white.setStroke()
            path.lineWidth = 2.4
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.2
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }()
}

@MainActor
final class TilePaneView: NSView {
    var tabID: UUID
    weak var canvas: TileCanvasView?
    var showsFocus = false {
        didSet { overlay.showsFocus = showsFocus }
    }
    var showsInactiveRing = false {
        didSet { overlay.showsInactive = showsInactiveRing }
    }
    var accessibilityTitle = "Pane" {
        didSet { setAccessibilityLabel(accessibilityTitle) }
    }

    private var fill: TilePaneFill = .page
    private var hosted: NSView?
    private var hostedInsets = NSEdgeInsets()
    private var pins: [NSLayoutConstraint] = []
    /// Set while the hosted web view is in element fullscreen. The next install pins it again.
    private var repinAfterFullscreen = false
    private let overlay = TileFocusOverlay()
    private let pill = TilePanePill()
    private var tracking: NSTrackingArea?
    private var hoverTimer: Timer?
    private var hoverReady = false
    private var pointerInTop = false

    init(tabID: UUID) {
        self.tabID = tabID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        applyLayerFill()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        pill.onMakeMain = { [weak self] in
            guard let self else { return }
            self.canvas?.onMakeMain?(self.tabID)
        }
        pill.onClose = { [weak self] in
            guard let self else { return }
            self.canvas?.onClosePane?(self.tabID)
        }
        pill.onMove = { [weak self] button in
            guard let self, let menu = self.canvas?.devToolsMoveMenu?(self.tabID) else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
        }
        pill.onPopOut = { [weak self] in
            guard let self else { return }
            self.canvas?.onPopOut?(self.tabID)
        }
        pill.onOverflow = { [weak self] button in
            guard let self else { return }
            self.canvas?.onDevToolsOverflow?(self.tabID, button)
        }
        pill.onDragPress = { [weak self] in
            guard let self else { return }
            self.canvas?.onPaneDragPress?(self.tabID)
        }
        pill.onDragChanged = { [weak self] point in
            guard let self else { return }
            self.canvas?.onPaneDragChanged?(self.tabID, point)
        }
        pill.onDragEnded = { [weak self] point in
            guard let self else { return }
            self.canvas?.onPaneDragEnded?(self.tabID, point)
        }
        addSubview(pill)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pane")
        setAccessibilityIdentifier("wyvern.tile.pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(_ presentation: TilePanePresentation?) {
        let insets = presentation?.insets ?? NSEdgeInsets()
        let nextFill = presentation?.fill ?? .page
        if fill != nextFill {
            fill = nextFill
            applyLayerFill()
            needsDisplay = true
        }
        let next = presentation?.content?.tileView
        // WebKit owns a web view while it is in element fullscreen. Leave it there and forget the
        // pins, so the next install after fullscreen ends pins it again in this pane.
        if let next, next.isInElementFullscreen {
            // Leave pins and `hosted` alone while WebKit snapshots and moves the view.
            repinAfterFullscreen = true
            return
        }
        if hosted === next, !repinAfterFullscreen, (next == nil || next?.superview === self), sameInsets(hostedInsets, insets) {
            next?.isHidden = false
            return
        }
        if hosted === next, let next, next.superview === self {
            next.isHidden = false
            replacePins(on: next, insets: insets)
            repinAfterFullscreen = false
            needsDisplay = true
            return
        }
        repinAfterFullscreen = false
        clearHost()
        guard let next else { return }
        // Already in this pane: do not remove it. Removal flashes a WKWebView.
        if HostedViewPlacement.shouldMove(isChildOfTarget: next.superview === self) {
            Self.detach(next)
            next.translatesAutoresizingMaskIntoConstraints = false
            next.isHidden = false
            next.setContentHuggingPriority(.defaultLow, for: .horizontal)
            next.setContentHuggingPriority(.defaultLow, for: .vertical)
            next.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            next.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            addSubview(next)
            addSubview(overlay)
            addSubview(pill)
        }
        replacePins(on: next, insets: insets)
        hosted = next
        hostedInsets = insets
    }

    private func replacePins(on view: NSView, insets: NSEdgeInsets) {
        NSLayoutConstraint.deactivate(pins)
        pins = [
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
        ]
        NSLayoutConstraint.activate(pins)
        hostedInsets = insets
    }

    private func applyLayerFill() {
        switch fill {
        case .page:
            layer?.backgroundColor = Theme.page.cgColor
        case .terminal:
            layer?.backgroundColor = Theme.termBackground.cgColor
        }
    }

    func clearHost() {
        NSLayoutConstraint.deactivate(pins)
        pins.removeAll()
        if let hosted, hosted.superview === self, !hosted.isInElementFullscreen {
            Self.detach(hosted)
        }
        hosted = nil
        hostedInsets = NSEdgeInsets()
    }

    func refreshChrome() {
        let inside = keyboardFocusIsInside()
        pill.isHidden = !(hoverReady || pointerInTop || inside || pill.isTrackingDrag)
        updateCornerRadii()
    }

    func setPillStyle(_ style: TilePanePillStyle) {
        if pill.setStyle(style) {
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let width = pill.preferredWidth
        let height: CGFloat = 22
        pill.frame = NSRect(
            x: bounds.width - 8 - width,
            y: bounds.height - 8 - height,
            width: width,
            height: height
        )
        updateCornerRadii()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hoverReady = true
                self?.refreshChrome()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        notePointer(event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverReady = false
        pointerInTop = false
        refreshChrome()
    }

    override func mouseMoved(with event: NSEvent) {
        notePointer(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch fill {
        case .page:
            Theme.page.setFill()
        case .terminal:
            Theme.termBackground.setFill()
        }
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerFill()
        needsDisplay = true
        overlay.needsDisplay = true
    }

    private func notePointer(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let inTop = showsFocus && local.y >= bounds.height - 48 && bounds.contains(local)
        if inTop != pointerInTop {
            pointerInTop = inTop
            refreshChrome()
        }
    }

    private func keyboardFocusIsInside() -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    private func updateCornerRadii() {
        guard let canvas else { return }
        let frame = convert(bounds, to: canvas)
        let slop: CGFloat = 1.5
        overlay.roundsBottomLeft = frame.minX <= slop && frame.minY <= slop
        overlay.roundsBottomRight = frame.maxX >= canvas.bounds.width - slop && frame.minY <= slop
    }

    private func sameInsets(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom && lhs.right == rhs.right
    }

    /// Drops constraints that pinned `view` to its previous parent. Each tab view has one parent.
    private static func detach(_ view: NSView) {
        guard let host = view.superview else { return }
        let attached = host.constraints.filter { constraint in
            let first = constraint.firstItem as AnyObject?
            let second = constraint.secondItem as AnyObject?
            return first === view || second === view
        }
        NSLayoutConstraint.deactivate(attached)
        view.removeFromSuperview()
    }
}

@MainActor
final class TileFocusOverlay: NSView {
    var showsFocus = false {
        didSet {
            guard showsFocus != oldValue else { return }
            needsDisplay = true
        }
    }
    var showsInactive = false {
        didSet {
            guard showsInactive != oldValue else { return }
            needsDisplay = true
        }
    }
    var roundsBottomLeft = false {
        didSet {
            guard roundsBottomLeft != oldValue else { return }
            needsDisplay = true
        }
    }
    var roundsBottomRight = false {
        didSet {
            guard roundsBottomRight != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Own layer, so a ring redraw does not clear the WKWebView under this overlay.
        wantsLayer = true
        layer?.isOpaque = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if showsFocus {
            Theme.accent.setStroke()
            strokeRing(lineWidth: MonoMetrics.paneRing)
        } else if showsInactive {
            Theme.line.setStroke()
            strokeRing(lineWidth: 1)
        }
    }

    private func strokeRing(lineWidth: CGFloat) {
        guard bounds.width > lineWidth * 2, bounds.height > lineWidth * 2 else { return }
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(MonoMetrics.windowRadius, min(rect.width, rect.height) / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY + (roundsBottomLeft ? radius : 0)))
        if roundsBottomLeft {
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
                radius: radius,
                startAngle: 180,
                endAngle: 270,
                clockwise: false
            )
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        }
        path.line(to: NSPoint(x: rect.maxX - (roundsBottomRight ? radius : 0), y: rect.minY))
        if roundsBottomRight {
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
                radius: radius,
                startAngle: 270,
                endAngle: 360,
                clockwise: false
            )
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.close()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

/// Hover pill. Web and terminal panes show Make Main and Close.
/// A DevTools pane shows Move, Pop Out to Tab, Close, and an overflow menu.
@MainActor
final class TilePanePill: NSView {
    var onMakeMain: (() -> Void)?
    var onClose: (() -> Void)?
    var onMove: ((NSView) -> Void)?
    var onPopOut: (() -> Void)?
    var onOverflow: ((NSView) -> Void)?
    var onDragPress: (() -> Void)?
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    private let moveButton = ToolButton()
    private let mainButton = ToolButton()
    private let closeButton = ToolButton()
    private let overflowButton = NSButton()
    private var style: TilePanePillStyle = .standard
    private var appliedStyle: TilePanePillStyle?
    private var moveWidth: NSLayoutConstraint?
    private var moveGap: NSLayoutConstraint?
    private var overflowWidth: NSLayoutConstraint?
    private var overflowGap: NSLayoutConstraint?
    private var dragOriginInWindow: NSPoint?
    private var dragArmed = false
    private var dragStarted = false
    private var pressedControl: NSView?

    var preferredWidth: CGFloat {
        let buttons: CGFloat = style == .devtools ? 4 : 2
        return 6 + buttons * 18 + (buttons - 1) * 4 + 8
    }

    var isTrackingDrag: Bool { dragArmed }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        isHidden = true
        configure(moveButton, glyph: .move, label: "Move", action: #selector(movePane))
        configure(mainButton, glyph: .expand, label: "Make Main Tab", action: #selector(makeMain))
        configure(closeButton, glyph: .close, label: "Close Pane", action: #selector(closePane))
        overflowButton.title = "⋯"
        overflowButton.isBordered = false
        overflowButton.font = Theme.font(size: 14, weight: .medium)
        overflowButton.contentTintColor = Theme.text
        overflowButton.toolTip = "More"
        overflowButton.setAccessibilityLabel("More")
        overflowButton.target = self
        overflowButton.action = #selector(overflow)
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        moveButton.translatesAutoresizingMaskIntoConstraints = false
        mainButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(moveButton)
        addSubview(mainButton)
        addSubview(closeButton)
        addSubview(overflowButton)
        let moveW = moveButton.widthAnchor.constraint(equalToConstant: 0)
        let moveG = mainButton.leadingAnchor.constraint(equalTo: moveButton.trailingAnchor, constant: 0)
        let overflowW = overflowButton.widthAnchor.constraint(equalToConstant: 0)
        let overflowG = overflowButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 0)
        moveWidth = moveW
        moveGap = moveG
        overflowWidth = overflowW
        overflowGap = overflowG
        NSLayoutConstraint.activate([
            moveButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            moveButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moveW,
            moveButton.heightAnchor.constraint(equalToConstant: 18),
            moveG,
            mainButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            mainButton.widthAnchor.constraint(equalToConstant: 18),
            mainButton.heightAnchor.constraint(equalToConstant: 18),
            closeButton.leadingAnchor.constraint(equalTo: mainButton.trailingAnchor, constant: 4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            overflowG,
            overflowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflowW,
            overflowButton.heightAnchor.constraint(equalToConstant: 18)
        ])
        setStyle(.standard)
    }

    @discardableResult
    func setStyle(_ style: TilePanePillStyle) -> Bool {
        guard appliedStyle != style else { return false }
        appliedStyle = style
        self.style = style
        let devtools = style == .devtools
        moveButton.isHidden = !devtools
        overflowButton.isHidden = !devtools
        moveWidth?.constant = devtools ? 18 : 0
        moveGap?.constant = devtools ? 4 : 0
        overflowWidth?.constant = devtools ? 18 : 0
        overflowGap?.constant = devtools ? 4 : 0
        if devtools {
            mainButton.glyph = .expand
            mainButton.toolTip = "Pop Out to Tab"
            mainButton.setAccessibilityLabel("Pop Out to Tab")
            closeButton.toolTip = "Close"
            closeButton.setAccessibilityLabel("Close")
        } else {
            mainButton.glyph = .expand
            mainButton.toolTip = "Make Main Tab"
            mainButton.setAccessibilityLabel("Make Main Tab")
            closeButton.toolTip = "Close Pane"
            closeButton.setAccessibilityLabel("Close Pane")
        }
        needsDisplay = true
        return true
    }

    private func configure(_ button: ToolButton, glyph: IconGlyph, label: String, action: Selector) {
        button.glyph = glyph
        button.pointSize = 14
        button.tint = Theme.text
        button.fill = .clear
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 6
        shadow.set()
        Theme.card.withAlphaComponent(0.92).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        Theme.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The pill owns the press so a drag from a button still swaps, and a click still fires.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        // `point` is in the superview's coordinates.
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        pressedControl = visibleControl(at: local)
        (pressedControl as? NSButton)?.isHighlighted = true
        dragOriginInWindow = event.locationInWindow
        dragArmed = true
        dragStarted = false
        onDragPress?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragArmed, let origin = dragOriginInWindow else { return }
        let dx = event.locationInWindow.x - origin.x
        let dy = event.locationInWindow.y - origin.y
        if !dragStarted {
            guard TabDragPolicy.dragHasStarted(travelSquared: Double(dx * dx + dy * dy)) else { return }
            dragStarted = true
            (pressedControl as? NSButton)?.isHighlighted = false
            pressedControl = nil
        }
        onDragChanged?(screenPoint(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        let started = dragStarted
        let control = pressedControl
        (control as? NSButton)?.isHighlighted = false
        dragArmed = false
        dragStarted = false
        dragOriginInWindow = nil
        pressedControl = nil
        if started {
            onDragEnded?(screenPoint(of: event))
            return
        }
        // Like a normal button: releasing off the pressed control cancels the click.
        guard let control, control.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        performPress(on: control)
    }

    private func visibleControl(at local: NSPoint) -> NSView? {
        let controls: [NSView] = [moveButton, mainButton, closeButton, overflowButton]
        return controls.first { !$0.isHidden && $0.frame.contains(local) }
    }

    private func performPress(on control: NSView?) {
        switch control {
        case moveButton: movePane()
        case mainButton: makeMain()
        case closeButton: closePane()
        case overflowButton: overflow()
        default: break
        }
    }

    private func screenPoint(of event: NSEvent) -> NSPoint {
        if let host = event.window {
            return host.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        }
        return NSEvent.mouseLocation
    }

    @objc private func makeMain() {
        if style == .devtools {
            onPopOut?()
        } else {
            onMakeMain?()
        }
    }
    @objc private func closePane() { onClose?() }
    @objc private func movePane() { onMove?(moveButton) }
    @objc private func overflow() { onOverflow?(overflowButton) }
}

/// One window's split tree and the canvas that draws it.
@MainActor
final class WindowTiles {
    private(set) var layout: TileLayout?
    let canvas = TileCanvasView()
    var contentForTab: ((UUID, Bool) -> TilePanePresentation?)?
    var onFocusTab: ((UUID) -> Void)?
    var onChange: (() -> Void)?

    private var ratioTimer: Timer?
    private var ratioStarted = Date()
    private var ratioPieces: [(UUID, [Double], [Double])] = []

    init() {
        canvas.onFocus = { [weak self] id in
            guard let self, let layout = self.layout, layout.contains(id) else { return }
            self.layout = layout.focusing(id)
            self.onFocusTab?(id)
        }
        canvas.onResize = { [weak self] splitID, divider, proposed, length, commit in
            guard let self, let layout = self.layout else { return }
            self.cancelRatioAnimation()
            let minimum = layout.split(id: splitID)?.axis == .vertical
                ? TileLayout.minimumPaneHeight
                : TileLayout.minimumPaneWidth
            self.layout = layout.resizing(
                splitID: splitID,
                divider: divider,
                proposedRatio: proposed,
                length: length,
                minimum: minimum
            )
            self.canvas.show(layout: self.layout, content: self.contentForTab)
            self.canvas.relayoutSplits()
            if commit {
                self.onChange?()
            }
        }
        canvas.onEqualize = { [weak self] splitID in
            self?.animateEqualize(splitID: splitID)
        }
        canvas.onMakeMain = { [weak self] id in
            self?.pendingMakeMain?(id)
        }
        canvas.onClosePane = { [weak self] id in
            self?.pendingClose?(id)
        }
    }

    var pendingMakeMain: ((UUID) -> Void)?
    var pendingClose: ((UUID) -> Void)?

    var hasSavedSplit: Bool {
        layout?.isSplit == true
    }

    func isSplitVisible(activeID: UUID?) -> Bool {
        guard let activeID, let layout, layout.isSplit else { return false }
        return layout.contains(activeID)
    }

    func tabIDs() -> [UUID] {
        layout?.tabIDs() ?? []
    }

    func focus(_ id: UUID) {
        guard let layout, layout.contains(id), layout.focusedTabID != id else { return }
        self.layout = layout.focusing(id)
    }

    /// Inserts `newTab` beside `anchor` using the five layouts.
    /// A split that does not contain `anchor` is left alone. A fifth pane is refused.
    @discardableResult
    func insert(newTab: UUID, beside anchor: UUID, axis: TileAxis) -> Bool {
        cancelRatioAnimation()
        let edge: TileEdge = axis == .horizontal ? .right : .down
        if let layout, layout.isSplit {
            guard layout.contains(anchor) else { return false }
            guard let next = layout.expanded(adding: newTab, beside: anchor, edge: edge) else { return false }
            self.layout = next
        } else {
            self.layout = TileLayout.split(anchor: anchor, newTab: newTab, axis: axis)
        }
        onChange?()
        return true
    }

    /// Places DevTools beside its page at 60/40 without snapping the tree onto even canonical ratios.
    @discardableResult
    func placeDevTools(devtools: UUID, beside source: UUID, side: DevToolsSide, pageFraction: Double) -> Bool {
        cancelRatioAnimation()
        guard devtools != source else { return false }
        if let layout, layout.isSplit, layout.contains(source) {
            let next = layout.placingDevTools(
                devtools: devtools,
                beside: source,
                side: side,
                pageFraction: pageFraction
            )
            guard next.contains(devtools), next.contains(source) else { return false }
            self.layout = next
            onChange?()
            return true
        }
        self.layout = DevToolsPlacement.pair(
            source: source,
            devtools: devtools,
            axis: side.axis,
            pageFraction: pageFraction,
            devtoolsFirst: side.devtoolsFirst
        )
        onChange?()
        return true
    }

    private func keepsDevToolsRatios(_ layout: TileLayout, kind: TabKind = .web) -> Bool {
        kind == .devtools || layout.panes().contains { $0.kind == .devtools }
    }

    /// Puts an existing tab into the split, or moves one that is already there.
    /// Does not replace a split when `anchor` is outside it.
    @discardableResult
    func place(tabID: UUID, beside anchor: UUID, edge: TileEdge, kind: TabKind) -> Bool {
        cancelRatioAnimation()
        guard tabID != anchor else { return false }
        if let layout, layout.isSplit {
            if layout.contains(tabID), layout.contains(anchor) {
                let moved = layout.moving(tabID: tabID, beside: anchor, edge: edge)
                let next = keepsDevToolsRatios(layout, kind: kind) ? moved : moved.canonicalized()
                guard next.contains(tabID) else { return false }
                self.layout = next.focusing(tabID)
                onChange?()
                return true
            }
            guard layout.contains(anchor), !layout.contains(tabID) else { return false }
            guard let next = layout.expanded(adding: tabID, beside: anchor, edge: edge, kind: kind) else { return false }
            self.layout = next
            onChange?()
            return true
        }
        let axis: TileAxis = (edge == .up || edge == .down) ? .vertical : .horizontal
        if edge == .left || edge == .up {
            layout = TileLayout.split(anchor: tabID, newTab: anchor, axis: axis).focusing(tabID)
        } else {
            layout = TileLayout.split(anchor: anchor, newTab: tabID, axis: axis).focusing(tabID)
        }
        onChange?()
        return true
    }

    func replaceLayout(_ layout: TileLayout?) {
        cancelRatioAnimation()
        self.layout = layout
        onChange?()
    }

    func stampKinds(_ kindFor: (UUID) -> TabKind?) {
        guard let layout else { return }
        let next = layout.applyingKinds(kindFor)
        if next != layout {
            self.layout = next
        }
    }

    /// Drops panes whose tabs are gone. Does not invent a new split.
    func prune(keeping ids: Set<UUID>) {
        guard let layout else { return }
        guard let next = layout.pruning(keeping: ids) else {
            if layout.tabIDs().contains(where: { !ids.contains($0) }) {
                self.layout = nil
                onChange?()
            }
            return
        }
        let canonical = keepsDevToolsRatios(layout) ? next : next.canonicalized()
        guard canonical != layout else { return }
        self.layout = canonical
        onChange?()
    }

    func replace(tabID: UUID, with newID: UUID, kind: TabKind) {
        guard let layout, layout.contains(tabID) else { return }
        cancelRatioAnimation()
        self.layout = layout.replacing(tabID: tabID, with: newID, kind: kind)
        onChange?()
    }

    /// Drops the pane. The returned id is the tab that should be focused when the closed pane had focus.
    /// A tab that was not in the split returns nil so the caller keeps its own next-tab rule.
    func remove(tabID: UUID) -> UUID? {
        guard let current = layout, current.contains(tabID) else { return nil }
        cancelRatioAnimation()
        let next = current.focus(afterRemoving: tabID)
        if let updated = current.removing(tabID: tabID) {
            let next = keepsDevToolsRatios(current) || keepsDevToolsRatios(updated) ? updated : updated.canonicalized()
            layout = next.isSplit ? next : nil
        } else {
            layout = nil
        }
        onChange?()
        return next
    }

    @discardableResult
    func focus(toward edge: TileEdge) -> UUID? {
        guard let layout, layout.isSplit else { return nil }
        guard let next = layout.neighbor(of: layout.focusedTabID, toward: edge) else { return nil }
        self.layout = layout.focusing(next)
        onChange?()
        return next
    }

    @discardableResult
    func swap(toward edge: TileEdge) -> Bool {
        guard let layout else { return false }
        let next = layout.swapping(toward: edge)
        guard next != layout else { return false }
        cancelRatioAnimation()
        self.layout = next
        onChange?()
        return true
    }

    /// Swaps two tiled occupants. Focus stays on `a`. Shape and ratios stay put.
    @discardableResult
    func swap(_ a: UUID, with b: UUID) -> Bool {
        guard let layout else { return false }
        let next = layout.swapping(a, b)
        guard next != layout else { return false }
        cancelRatioAnimation()
        self.layout = next.contains(a) ? next.focusing(a) : next
        onChange?()
        return true
    }

    func focusAdjacent(forward: Bool) -> UUID? {
        guard let layout, layout.isSplit else { return nil }
        let next = layout.focusingNext(forward: forward)
        self.layout = next
        onChange?()
        return next.focusedTabID
    }

    func equalizeAll() {
        guard let layout else { return }
        let pieces = Self.ratioPieces(in: layout.root, equalize: true)
        animate(pieces: pieces, final: layout.equalized())
    }

    func unsplit() {
        guard layout != nil else { return }
        cancelRatioAnimation()
        layout = nil
        onChange?()
    }

    func clear() {
        cancelRatioAnimation()
        layout = nil
        release()
    }

    func present() {
        canvas.isHidden = false
        // Do not addSubview the canvas here. It is already in the page host, and
        // addSubview removes and reinserts it, which flashes every pane web view.
        canvas.show(layout: layout, content: contentForTab)
    }

    func release() {
        canvas.show(layout: nil, content: contentForTab)
        canvas.isHidden = true
    }

    func capture(indexOf: (UUID) -> Int?) -> SessionTileSnapshot? {
        guard let layout, layout.isSplit else { return nil }
        return layout.sessionSnapshot(indexOfTab: indexOf)
    }

    func restore(_ snapshot: SessionTileSnapshot?, tabID: (Int) -> UUID?) {
        cancelRatioAnimation()
        guard let snapshot else {
            layout = nil
            return
        }
        layout = TileLayout.restored(snapshot, tabID: tabID)
    }

    private func animateEqualize(splitID: UUID) {
        guard let layout, let split = layout.split(id: splitID) else { return }
        let target = TileLayout.sanitizedRatios([], count: split.ratios.count)
        let final = layout.equalizing(splitID: splitID)
        animate(pieces: [(splitID, split.ratios, target)], final: final)
    }

    private func animate(pieces: [(UUID, [Double], [Double])], final: TileLayout) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cancelRatioAnimation()
            layout = final
            canvas.show(layout: layout, content: contentForTab)
            canvas.relayoutSplits()
            onChange?()
            return
        }
        cancelRatioAnimation()
        ratioPieces = pieces
        ratioStarted = Date()
        layout = apply(pieces: pieces, progress: 0)
        canvas.show(layout: layout, content: contentForTab)
        canvas.relayoutSplits()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                self?.stepAnimation(timer, final: final)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ratioTimer = timer
    }

    private func stepAnimation(_ timer: Timer, final: TileLayout) {
        let elapsed = Date().timeIntervalSince(ratioStarted)
        let linear = min(1, elapsed / 0.18)
        let progress = 1 - pow(1 - linear, 3)
        if linear >= 1 {
            timer.invalidate()
            ratioTimer = nil
            layout = final
            canvas.show(layout: layout, content: contentForTab)
            canvas.relayoutSplits()
            onChange?()
            return
        }
        layout = apply(pieces: ratioPieces, progress: progress)
        canvas.show(layout: layout, content: contentForTab)
        canvas.relayoutSplits()
    }

    private func apply(pieces: [(UUID, [Double], [Double])], progress: Double) -> TileLayout? {
        guard var current = layout else { return nil }
        for piece in pieces {
            let ratios = zip(piece.1, piece.2).map { from, to in
                from + (to - from) * progress
            }
            current = current.settingRatios(splitID: piece.0, ratios: ratios)
        }
        return current
    }

    private func cancelRatioAnimation() {
        ratioTimer?.invalidate()
        ratioTimer = nil
        ratioPieces = []
    }

    private static func ratioPieces(in node: TileNode, equalize: Bool) -> [(UUID, [Double], [Double])] {
        guard case .split(let split) = node else { return [] }
        let target = TileLayout.sanitizedRatios([], count: split.children.count)
        var pieces = [(split.id, split.ratios, target)]
        for child in split.children {
            pieces.append(contentsOf: ratioPieces(in: child, equalize: equalize))
        }
        return pieces
    }
}
