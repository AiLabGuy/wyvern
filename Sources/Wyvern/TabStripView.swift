// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit

/// Distances are in points. A click shorter than `startDistance` never becomes a drag.
enum TabDrag {
    static let startDistance: CGFloat = 4
    static let detachDistance: CGFloat = 24
}

struct TabStripItem: Equatable {
    var id: UUID
    var title: String
    var badgeLetter: String
    var badgeHex: String
    var favicon: NSImage?
    var selected: Bool
    /// True for every tab in the saved split, including while a non-member is selected.
    var groupMember: Bool = false
    /// Mini split glyph drawn before the favicon while this tab is in the saved split.
    var splitGlyph: IconGlyph? = nil
    /// How many tabs are in the saved split. Members use a 140 pt width at 3 or 4.
    var memberCount: Int = 0
    var kind: TabKind = .web
    var glyph: IconGlyph?
    /// Mute prefix that never truncates, for example "DevTools:".
    var titlePrefix: String? = nil
    /// Page title shown after the prefix. The full `title` stays in the tooltip.
    var pageTitle: String? = nil
    /// The other tab in a DevTools pair.
    var partnerID: UUID? = nil
    /// `{}` tile in place of the favicon.
    var devtoolsTile: Bool = false
    var accessibilityLabel: String?
    var accessibilityValue: String?
    var accessibilityHelp: String?

    static func == (lhs: TabStripItem, rhs: TabStripItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.badgeLetter == rhs.badgeLetter
            && lhs.badgeHex == rhs.badgeHex
            && lhs.selected == rhs.selected
            && lhs.groupMember == rhs.groupMember
            && lhs.splitGlyph == rhs.splitGlyph
            && lhs.memberCount == rhs.memberCount
            && lhs.kind == rhs.kind
            && lhs.glyph == rhs.glyph
            && lhs.titlePrefix == rhs.titlePrefix
            && lhs.pageTitle == rhs.pageTitle
            && lhs.partnerID == rhs.partnerID
            && lhs.devtoolsTile == rhs.devtoolsTile
            && lhs.accessibilityLabel == rhs.accessibilityLabel
            && lhs.accessibilityValue == rhs.accessibilityValue
            && lhs.accessibilityHelp == rhs.accessibilityHelp
            && (lhs.favicon == nil) == (rhs.favicon == nil)
    }
}

/// Tabs plus the new-tab button. The region clips.
@MainActor
final class TabRegionView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var contextMenuForTab: ((UUID) -> NSMenu?)?
    /// Screen point of a tab drag that has passed the start distance. The window uses it for the drop preview.
    var onTabDrag: ((UUID, NSPoint) -> Void)?
    /// Right click on the new-tab button. Left click stays a new web tab.
    var onTerminalPicker: ((NSView) -> Void)?

    private let stack = NSStackView()
    private let capsule = SplitGroupCapsule()
    private let links = DevToolsLinkOverlay()
    private let plus = ToolButton()
    private var itemViews: [UUID: TabItemView] = [:]
    private var displayed: [TabStripItem] = []
    /// Pins the capsule to the first and last member. A frame copied during reorder
    /// stayed on the old slots after the stack moved the tabs.
    private var capsulePins: [NSLayoutConstraint] = []
    private weak var pinnedCapsuleFirst: TabItemView?
    private weak var pinnedCapsuleLast: TabItemView?

    /// Left click opens a web tab. The menu lists terminal bookmarks.
    var newTabButton: NSView { plus }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = MonoMetrics.tabGap
        stack.translatesAutoresizingMaskIntoConstraints = false

        plus.glyph = .plus
        plus.pointSize = MonoMetrics.plusGlyph
        plus.tint = Theme.mute
        plus.toolTip = "New Tab"
        plus.setAccessibilityLabel("New Tab")
        plus.setAccessibilityIdentifier("wyvern.newtab.button")
        plus.target = self
        plus.action = #selector(newTabTapped)
        plus.onContextMenu = { [weak self] in
            guard let self else { return }
            self.onTerminalPicker?(self.plus)
        }
        plus.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            plus.widthAnchor.constraint(equalToConstant: MonoMetrics.control),
            plus.heightAnchor.constraint(equalToConstant: MonoMetrics.control)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        stack.setAccessibilityElement(false)

        capsule.translatesAutoresizingMaskIntoConstraints = true
        links.translatesAutoresizingMaskIntoConstraints = true
        addSubview(capsule)
        addSubview(stack)
        addSubview(links)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: MonoMetrics.tabHeight)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(items: [TabStripItem]) {
        if items.count == displayed.count,
           zip(items, displayed).allSatisfy({ next, previous in
               next == previous && next.favicon === previous.favicon
           }) {
            return
        }
        displayed = items
        // Drop pins before tabs leave the stack. A constraint onto a removed view is invalid.
        clearCapsulePins()
        let remaining = Set(items.map(\.id))
        for (id, view) in itemViews where !remaining.contains(id) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
            itemViews.removeValue(forKey: id)
        }
        if plus.superview != nil {
            stack.removeArrangedSubview(plus)
            plus.removeFromSuperview()
        }
        for (index, item) in items.enumerated() {
            let view: TabItemView
            if let existing = itemViews[item.id] {
                view = existing
                view.apply(item, index: index)
            } else {
                view = TabItemView(item: item, index: index)
                view.translatesAutoresizingMaskIntoConstraints = false
                itemViews[item.id] = view
                let width = view.widthAnchor.constraint(equalToConstant: MonoMetrics.tabWidth)
                view.attachWidth(width)
                NSLayoutConstraint.activate([
                    width,
                    view.heightAnchor.constraint(equalToConstant: MonoMetrics.tabHeight)
                ])
                view.apply(item, index: index)
            }
            view.onSelect = { [weak self] in self?.onSelect?(item.id) }
            view.onClose = { [weak self] in self?.onClose?(item.id) }
            view.onDragChanged = { [weak self] point in self?.onTabDrag?(item.id, point) }
            view.onHover = { [weak self] inside in
                self?.hoverPartner(of: item.id, inside: inside)
            }
            view.contextMenuProvider = { [weak self] in self?.contextMenuForTab?(item.id) }
            let arranged = stack.arrangedSubviews
            if index < arranged.count, arranged[index] === view {
                continue
            }
            // Drop the old subview slot too. removeArrangedSubview alone leaves the view
            // in `subviews`, and the stack then lays the tab out at its previous index.
            if view.superview === stack {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            let slot = min(index, stack.arrangedSubviews.count)
            stack.insertArrangedSubview(view, at: slot)
        }
        stack.addArrangedSubview(plus)
        linkPartners()
        syncCapsulePins()
        needsLayout = true
    }

    /// The capsule tracks the member views. Measuring frames inside `layout` kept the
    /// pill on the pre-reorder slots (the active tab and the one before it) while the
    /// glyphs moved with the members.
    private func syncCapsulePins() {
        let ids = displayed.map(\.id)
        var members = Set<UUID>()
        for item in displayed where item.groupMember {
            members.insert(item.id)
        }
        let tabs = ids.compactMap { itemViews[$0] }
        let span = tabs.count == ids.count ? TileStripGroup.memberSpan(session: ids, members: members) : nil
        guard let span else {
            clearCapsulePins()
            return
        }
        let first = tabs[span.lowerBound]
        let last = tabs[span.upperBound]
        if pinnedCapsuleFirst !== first || pinnedCapsuleLast !== last || capsulePins.isEmpty {
            clearCapsulePins()
            capsule.translatesAutoresizingMaskIntoConstraints = false
            let pins = [
                capsule.leadingAnchor.constraint(equalTo: first.leadingAnchor),
                capsule.trailingAnchor.constraint(equalTo: last.trailingAnchor),
                capsule.topAnchor.constraint(equalTo: first.topAnchor),
                capsule.bottomAnchor.constraint(equalTo: last.bottomAnchor)
            ]
            // Below required so a pin cannot override a tab's width constraint.
            let belowRequired = NSLayoutConstraint.Priority(rawValue: 999)
            for pin in pins {
                pin.priority = belowRequired
            }
            NSLayoutConstraint.activate(pins)
            capsulePins = pins
            pinnedCapsuleFirst = first
            pinnedCapsuleLast = last
        }
        if capsule.isHidden {
            capsule.isHidden = false
        }
        let elevated = displayed.contains { $0.groupMember && $0.selected }
        if capsule.elevated != elevated {
            capsule.elevated = elevated
        }
    }

    private func clearCapsulePins() {
        if !capsulePins.isEmpty {
            NSLayoutConstraint.deactivate(capsulePins)
            capsulePins.removeAll()
        }
        pinnedCapsuleFirst = nil
        pinnedCapsuleLast = nil
        // No pins: an unconstrained capsule (translates off, hidden) is an ambiguous layout.
        capsule.translatesAutoresizingMaskIntoConstraints = true
        if !capsule.isHidden {
            capsule.isHidden = true
        }
    }

    private func hoverPartner(of id: UUID, inside: Bool) {
        guard let item = displayed.first(where: { $0.id == id }), let partner = item.partnerID else { return }
        itemViews[partner]?.setPartnerHighlight(inside)
    }

    private func linkPartners() {
        for item in displayed {
            guard let view = itemViews[item.id] else { continue }
            if let partner = item.partnerID, let other = itemViews[partner] {
                view.setAccessibilityLinkedUIElements([other])
            } else {
                view.setAccessibilityLinkedUIElements(nil)
            }
        }
    }

    /// Orders the drag image out. The window decides whether the drop is kept.
    func cancelTabDrags() {
        for view in itemViews.values {
            view.cancelDragSession()
        }
    }

    override func layout() {
        super.layout()
        placeLinks()
    }

    /// 6×2 accent bar across the 2 px gap, plus a 4 px dot on each tab edge.
    /// Design y = 19 from the top of the 30 px tab. The view is not flipped.
    private func placeLinks() {
        if links.frame != bounds {
            links.frame = bounds
        }
        var drawn: [DevToolsLinkOverlay.Link] = []
        let tabs = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        if displayed.count == tabs.count {
            for (index, item) in displayed.enumerated() {
                guard let partner = item.partnerID, index + 1 < displayed.count,
                      displayed[index + 1].id == partner else { continue }
                let left = tabs[index].convert(tabs[index].bounds, to: self)
                let right = tabs[index + 1].convert(tabs[index + 1].bounds, to: self)
                let midY = left.minY + (left.height - 19)
                drawn.append(DevToolsLinkOverlay.Link(
                    gapMidX: (left.maxX + right.minX) / 2,
                    midY: midY,
                    leftEdgeX: left.maxX,
                    rightEdgeX: right.minX
                ))
            }
        }
        if links.links != drawn {
            links.links = drawn
        }
        let hideLinks = drawn.isEmpty
        if links.isHidden != hideLinks {
            links.isHidden = hideLinks
        }
    }

    func itemView(id: UUID) -> TabItemView? {
        itemViews[id]
    }

    /// Vertical distance from this strip to a Cocoa screen point. Inside the strip is 0.
    func verticalDistance(toScreenPoint screenPoint: NSPoint) -> CGFloat {
        guard let window else { return CGFloat.greatestFiniteMagnitude }
        let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        if bounds.contains(local) {
            return 0
        }
        if local.y < bounds.minY {
            return bounds.minY - local.y
        }
        if local.y > bounds.maxY {
            return local.y - bounds.maxY
        }
        return 0
    }

    /// Insertion index for a Cocoa screen point, using each tab's horizontal midpoint.
    func dropIndex(atScreenPoint screenPoint: NSPoint) -> Int {
        guard let window else { return 0 }
        let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return dropIndex(atLocalX: local.x)
    }

    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return bounds.contains(local)
    }

    private func dropIndex(atLocalX x: CGFloat) -> Int {
        var tabIndex = 0
        for view in stack.arrangedSubviews {
            guard let tab = view as? TabItemView else { continue }
            let frame = tab.convert(tab.bounds, to: self)
            if x < frame.midX {
                return tabIndex
            }
            tabIndex += 1
        }
        return tabIndex
    }

    override func accessibilityChildren() -> [Any]? {
        stack.arrangedSubviews.filter { view in
            view is TabItemView || view === plus
        }
    }

    /// Only empty strip space drags the window. Tabs and buttons hit-test before this view.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    @objc private func newTabTapped() {
        onNewTab?()
    }
}

/// Stock borderless `NSButton`: tracks the click and sends its action on mouse-up inside.
@MainActor
final class TabCloseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

@MainActor
final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragChanged: ((NSPoint) -> Void)?
    var onHover: ((Bool) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    private var selected = false
    private var groupMember = false
    private var hovering = false
    private var kind: TabKind = .web
    private var devtoolsTile = false
    private var tracking: NSTrackingArea?
    private let badge = LetterBadgeView()
    private let splitMark = GlyphView()
    private let mark = GlyphView()
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let prefixField = NSTextField(labelWithString: "")
    private let braces = DevToolsBracesView()
    private let partnerRing = DevToolsPartnerRing()
    private let closeButton = TabCloseButton()
    private var prefixWidth: NSLayoutConstraint?
    private var prefixGap: NSLayoutConstraint?
    private var closeWidth: NSLayoutConstraint?
    private var closeGap: NSLayoutConstraint?
    private var splitMarkWidth: NSLayoutConstraint?
    private var splitMarkGap: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private let tabID: UUID
    private var dragOriginInWindow: NSPoint?
    /// Cocoa screen point of mouse-down. Synthetic drags can leave `locationInWindow` stuck.
    private var dragOriginOnScreen: NSPoint?
    private var dragCursorInTab: NSPoint = .zero
    private var dragArmed = false
    private var dragWindow: TabDragImageWindow?

    init(item: TabStripItem, index: Int) {
        tabID = item.id
        super.init(frame: .zero)
        badge.cornerRadius = MonoMetrics.faviconRadius
        badge.fontSize = 9
        badge.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = MonoMetrics.faviconRadius
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.isHidden = true
        splitMark.translatesAutoresizingMaskIntoConstraints = false
        splitMark.isHidden = true
        splitMark.pointSize = 12
        splitMark.tint = Theme.mute

        titleField.font = Theme.font(size: 12)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setAccessibilityElement(false)
        prefixField.font = Theme.font(size: 12, weight: .medium)
        prefixField.textColor = Theme.mute
        prefixField.lineBreakMode = .byClipping
        prefixField.maximumNumberOfLines = 1
        prefixField.translatesAutoresizingMaskIntoConstraints = false
        prefixField.setContentCompressionResistancePriority(.required, for: .horizontal)
        prefixField.setContentHuggingPriority(.required, for: .horizontal)
        prefixField.setAccessibilityElement(false)
        braces.translatesAutoresizingMaskIntoConstraints = false
        braces.isHidden = true
        partnerRing.translatesAutoresizingMaskIntoConstraints = false
        partnerRing.alphaValue = 0
        badge.setAccessibilityElement(false)
        imageView.setAccessibilityElement(false)

        closeButton.title = ""
        closeButton.isBordered = false
        closeButton.bezelStyle = .shadowlessSquare
        closeButton.setButtonType(.momentaryChange)
        closeButton.image = IconDrawing.templateImage(.close, pointSize: MonoMetrics.closeIcon)
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleNone
        closeButton.focusRingType = .none
        closeButton.toolTip = "Close Tab"
        closeButton.setAccessibilityLabel("Close Tab")
        closeButton.setAccessibilityRole(.button)
        closeButton.setAccessibilityElement(true)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(partnerRing)
        addSubview(splitMark)
        addSubview(badge)
        addSubview(braces)
        addSubview(mark)
        addSubview(imageView)
        addSubview(prefixField)
        addSubview(titleField)
        addSubview(closeButton)

        let width = closeButton.widthAnchor.constraint(equalToConstant: 0)
        let gap = titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: 0)
        let glyphWidth = splitMark.widthAnchor.constraint(equalToConstant: 0)
        let glyphGap = badge.leadingAnchor.constraint(equalTo: splitMark.trailingAnchor, constant: 0)
        let prefixW = prefixField.widthAnchor.constraint(equalToConstant: 0)
        let prefixG = titleField.leadingAnchor.constraint(equalTo: prefixField.trailingAnchor, constant: 0)
        closeWidth = width
        closeGap = gap
        splitMarkWidth = glyphWidth
        splitMarkGap = glyphGap
        prefixWidth = prefixW
        prefixGap = prefixG
        NSLayoutConstraint.activate([
            partnerRing.leadingAnchor.constraint(equalTo: leadingAnchor),
            partnerRing.trailingAnchor.constraint(equalTo: trailingAnchor),
            partnerRing.topAnchor.constraint(equalTo: topAnchor),
            partnerRing.bottomAnchor.constraint(equalTo: bottomAnchor),
            splitMark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MonoMetrics.tabPadding),
            splitMark.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphWidth,
            splitMark.heightAnchor.constraint(equalToConstant: 12),
            glyphGap,
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            badge.heightAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            braces.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            braces.centerYAnchor.constraint(equalTo: centerYAnchor),
            braces.widthAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            braces.heightAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            mark.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            mark.heightAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            imageView.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            imageView.heightAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            prefixField.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: MonoMetrics.tabInnerGap),
            prefixField.centerYAnchor.constraint(equalTo: centerYAnchor),
            prefixW,
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            prefixG,
            gap,
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MonoMetrics.tabPadding),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            width,
            closeButton.heightAnchor.constraint(equalToConstant: MonoMetrics.closeHit)
        ])
        apply(item, index: index)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attachWidth(_ constraint: NSLayoutConstraint) {
        widthConstraint = constraint
    }

    /// Hides the floating drag image. Mouse-up still reaches the window, which drops the drag.
    func cancelDragSession() {
        dragWindow?.orderOut(nil)
        dragWindow = nil
        dragArmed = false
    }

    func apply(_ item: TabStripItem, index: Int) {
        selected = item.selected
        groupMember = item.groupMember
        kind = item.kind
        devtoolsTile = item.devtoolsTile
        let tabWidth: CGFloat = (item.groupMember && item.memberCount >= 3) ? 140 : MonoMetrics.tabWidth
        widthConstraint?.constant = tabWidth
        braces.isHidden = !item.devtoolsTile
        applyPrefix(item.titlePrefix, tabWidth: tabWidth)
        if let glyph = item.splitGlyph {
            splitMark.glyph = glyph
            splitMark.pointSize = 12
            splitMark.tint = Theme.mute
            splitMark.isHidden = false
            splitMarkWidth?.constant = 12
            splitMarkGap?.constant = 4
        } else {
            splitMark.isHidden = true
            splitMarkWidth?.constant = 0
            splitMarkGap?.constant = 0
        }
        toolTip = item.title
        badge.letter = item.badgeLetter
        badge.hex = item.badgeHex
        imageView.image = item.favicon
        titleField.font = item.kind == .terminal
            ? Theme.mono(size: MonoMetrics.terminalLabel)
            : Theme.font(size: MonoMetrics.tabLabel)
        titleField.stringValue = item.pageTitle ?? item.title
        titleField.textColor = item.devtoolsTile ? memberTitleColor : memberTitleColor
        if item.devtoolsTile {
            prefixField.textColor = Theme.mute
        }
        closeButton.contentTintColor = memberTitleColor
        if let glyph = item.glyph {
            mark.glyph = glyph
            mark.pointSize = MonoMetrics.tabIcon
            mark.tint = item.kind == .terminal ? Theme.termGlyph : (showsGroupStyle ? Theme.text : Theme.mute)
            mark.isHidden = false
            badge.isHidden = true
            imageView.isHidden = true
        } else {
            mark.isHidden = true
            let showImage = item.favicon != nil
            imageView.isHidden = !showImage
            badge.isHidden = showImage
        }
        if item.devtoolsTile {
            mark.isHidden = true
            imageView.isHidden = true
            badge.isHidden = true
            braces.isHidden = false
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        if item.devtoolsTile {
            setAccessibilityIdentifier("wyvern.devtools.tab.\(index)")
        } else {
            setAccessibilityIdentifier("wyvern.tab.\(index)")
        }
        setAccessibilityLabel(item.accessibilityLabel ?? item.title)
        if let value = item.accessibilityValue {
            setAccessibilityValue(value)
        }
        if let help = item.accessibilityHelp {
            setAccessibilityHelp(help)
        }
        setAccessibilitySelected(item.selected)
        if item.devtoolsTile {
            closeButton.setAccessibilityIdentifier("wyvern.devtools.tab.\(index).close")
        } else {
            closeButton.setAccessibilityIdentifier("wyvern.tab.\(index).close")
        }
        revealClose(showsGroupStyle || hovering)
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    override func accessibilityChildren() -> [Any]? {
        closeButton.isHidden ? [] : [closeButton]
    }

    override func draw(_ dirtyRect: NSRect) {
        // Grouped tabs leave the fill to the capsule so members do not each draw a raised tab.
        if groupMember { return }
        let path = Theme.tabPath(bounds, radius: MonoMetrics.tabRadius)
        if kind == .terminal {
            Theme.termTab.setFill()
            path.fill()
            Theme.termOutline.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return
        }
        guard selected else { return }
        Theme.fillRaisedTab(top: Theme.tabA1, bottom: Theme.tabA2, path: path, in: bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    /// The close button gets points inside it; the rest of the tab (title, badge) is this view.
    /// `point` is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !closeButton.isHidden {
            let closeLocal = closeButton.convert(local, from: self)
            if closeButton.bounds.contains(closeLocal) {
                return closeButton
            }
        }
        return self
    }

    /// Selects on mouse-down and returns. There is no tracking loop here: a click's mouse-up
    /// stays with this view, and the close button never enters this method (`hitTest` returns
    /// the button for points inside it). A drag starts later, from `mouseDragged`, after the
    /// pointer moves `TabDrag.startDistance`.
    override func mouseDown(with event: NSEvent) {
        dragOriginInWindow = event.locationInWindow
        dragCursorInTab = convert(event.locationInWindow, from: nil)
        dragArmed = true
        if let host = event.window ?? window {
            dragOriginOnScreen = host.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        } else {
            dragOriginOnScreen = NSEvent.mouseLocation
        }
        (window?.windowController as? BrowserWindowController)?.prepareTabDrag()
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragArmed, dragOriginInWindow != nil else { return }
        let moved = max(windowTravel(of: event), pointerTravel())
        guard moved >= TabDrag.startDistance * TabDrag.startDistance || dragWindow != nil else { return }
        let screen = dragPoint(for: event)
        if dragWindow == nil {
            showDragImage(at: screen)
        } else {
            moveDragImage(to: screen)
        }
        onDragChanged?(screen)
    }

    override func mouseUp(with event: NSEvent) {
        let screen = dragPoint(for: event)
        // A posted drag can move only `locationInWindow`, or only `NSEvent.mouseLocation`.
        let travelled = max(windowTravel(of: event), pointerTravel())
        let started = dragWindow != nil
        // A HID drag can deliver mouse-up with the cursor already past the strip and
        // never deliver mouseDragged. The distance from mouse-down is the same threshold.
        let crossed = travelled >= TabDrag.startDistance * TabDrag.startDistance
        let imageWindow = dragWindow
        let offset = dragCursorInTab
        let id = tabID
        let controller = window?.windowController as? BrowserWindowController
        let cancelled = controller?.consumeTileDragCancellation() ?? false
        dragWindow = nil
        dragArmed = false
        dragOriginInWindow = nil
        dragOriginOnScreen = nil
        // Order the bitmap out before mouse-up returns so it is not a leftover window.
        // Move the tab on the next turn: this view must still be in the strip while the
        // click or drag's mouse-up is delivered, and the close button is a different view.
        imageWindow?.orderOut(nil)
        guard (started || crossed), let controller else { return }
        DispatchQueue.main.async { [weak controller] in
            MainActor.assumeIsolated {
                controller?.finishTabDrag(
                    tabID: id,
                    screenPoint: screen,
                    cursorOffsetInTab: offset,
                    cancelled: cancelled
                )
            }
        }
    }

    /// Squared distance of this event from mouse-down, in window points.
    private func windowTravel(of event: NSEvent) -> CGFloat {
        guard let origin = dragOriginInWindow else { return 0 }
        let dx = event.locationInWindow.x - origin.x
        let dy = event.locationInWindow.y - origin.y
        return dx * dx + dy * dy
    }

    /// Squared distance of the live cursor from the mouse-down screen point.
    /// Posted drags update `NSEvent.mouseLocation` even when `locationInWindow` stays put.
    private func pointerTravel() -> CGFloat {
        guard let origin = dragOriginOnScreen else { return 0 }
        let cursor = NSEvent.mouseLocation
        let dx = cursor.x - origin.x
        let dy = cursor.y - origin.y
        return dx * dx + dy * dy
    }

    /// Screen point of the drag. Prefer the live cursor when the event location did not move.
    private func dragPoint(for event: NSEvent) -> NSPoint {
        let fromEvent = screenPoint(of: event)
        let cursor = NSEvent.mouseLocation
        guard let origin = dragOriginOnScreen else { return cursor }
        let eventDx = fromEvent.x - origin.x
        let eventDy = fromEvent.y - origin.y
        let cursorDx = cursor.x - origin.x
        let cursorDy = cursor.y - origin.y
        if cursorDx * cursorDx + cursorDy * cursorDy > eventDx * eventDx + eventDy * eventDy + 0.25 {
            return cursor
        }
        return fromEvent
    }

    private func showDragImage(at screen: NSPoint) {
        layoutSubtreeIfNeeded()
        let image = snapshotImage()
        let floating = TabDragImageWindow(image: image)
        dragWindow = floating
        moveDragImage(to: screen)
        floating.orderFrontRegardless()
    }

    private func moveDragImage(to screen: NSPoint) {
        dragWindow?.setFrameOrigin(NSPoint(
            x: screen.x - dragCursorInTab.x,
            y: screen.y - dragCursorInTab.y
        ))
    }

    private func screenPoint(of event: NSEvent) -> NSPoint {
        if let host = event.window {
            return host.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        }
        return NSEvent.mouseLocation
    }

    private func snapshotImage() -> NSImage {
        let size = NSSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        guard bounds.width > 1, bounds.height > 1,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return solidSnapshot(size)
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private func solidSnapshot(_ size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()
        image.unlockFocus()
        return image
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
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

    func setPartnerHighlight(_ on: Bool) {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            partnerRing.animator().alphaValue = on ? 1 : 0
        }
    }

    private func applyPrefix(_ prefix: String?, tabWidth: CGFloat) {
        let show = devtoolsTile && prefix != nil && tabWidth >= 120
        if show, let prefix {
            prefixWidth?.isActive = false
            prefixField.stringValue = prefix
            prefixField.isHidden = false
            prefixField.textColor = Theme.mute
            prefixGap?.constant = 4
        } else {
            prefixField.stringValue = ""
            prefixField.isHidden = true
            prefixGap?.constant = 0
            prefixWidth?.constant = 0
            prefixWidth?.isActive = true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        revealClose(true)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        revealClose(showsGroupStyle)
        onHover?(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        titleField.textColor = memberTitleColor
        splitMark.tint = Theme.mute
        mark.tint = kind == .terminal ? Theme.termGlyph : (showsGroupStyle ? Theme.text : Theme.mute)
    }

    /// Focused member is full `text`. Other members are `text` at 75%. A tab outside the split stays `mute` until selected.
    private var memberTitleColor: NSColor {
        if groupMember {
            return selected ? Theme.text : Theme.text.withAlphaComponent(0.75)
        }
        return selected ? Theme.text : Theme.mute
    }

    private var showsGroupStyle: Bool {
        selected || groupMember
    }

    private func revealClose(_ show: Bool) {
        closeButton.isHidden = !show
        closeWidth?.constant = show ? MonoMetrics.closeHit : 0
        closeGap?.constant = show ? -MonoMetrics.tabInnerGap : 0
    }

    /// Closing removes this view (and the button) from the strip. Do it after the button's own
    /// tracking has returned, so the button is not released inside its mouse-up handling.
    @objc private func closeTapped() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onClose?()
            }
        }
    }
}

/// Bitmap of a tab that follows the pointer. It is not a browser window: it cannot become key,
/// it ignores the mouse so the tab still receives mouse-up, and it is ordered out before the drop.
final class TabDragImageWindow: NSWindow {
    init(image: NSImage) {
        let size = NSSize(width: max(image.size.width, 1), height: max(image.size.height, 1))
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Above normal browser windows. `CGWindowLevelKey.draggingWindow` is the drag-image level.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)))
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        contentView = imageView
        alphaValue = 0.94
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Ring around the tiled tabs. Dimmer while a non-member is selected; active-tab elevation when a member is.
@MainActor
final class SplitGroupCapsule: NSView {
    var elevated = false {
        didSet {
            guard elevated != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        guard rect.width > 1, rect.height > 1 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        if elevated {
            Theme.fillRaisedTab(top: Theme.tabA1, bottom: Theme.tabA2, path: path, in: rect)
        } else {
            Theme.accent.withAlphaComponent(0.10).setFill()
            path.fill()
        }
        Theme.accent.withAlphaComponent(elevated ? 0.45 : 0.28).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
