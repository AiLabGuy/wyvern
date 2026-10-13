// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import App1Core
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
    var kind: TabKind = .web
    var glyph: IconGlyph?
    var accessibilityLabel: String?
    var accessibilityValue: String?
    var accessibilityHelp: String?

    static func == (lhs: TabStripItem, rhs: TabStripItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.badgeLetter == rhs.badgeLetter
            && lhs.badgeHex == rhs.badgeHex
            && lhs.selected == rhs.selected
            && lhs.kind == rhs.kind
            && lhs.glyph == rhs.glyph
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
    /// Right click on the new-tab button. Left click stays a new web tab.
    var onTerminalPicker: ((NSView) -> Void)?

    private let stack = NSStackView()
    private let plus = ToolButton()
    private var itemViews: [UUID: TabItemView] = [:]

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
        plus.setAccessibilityIdentifier("app1.newtab.button")
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

        addSubview(stack)
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
                NSLayoutConstraint.activate([
                    view.widthAnchor.constraint(equalToConstant: MonoMetrics.tabWidth),
                    view.heightAnchor.constraint(equalToConstant: MonoMetrics.tabHeight)
                ])
            }
            view.onSelect = { [weak self] in self?.onSelect?(item.id) }
            view.onClose = { [weak self] in self?.onClose?(item.id) }
            let arranged = stack.arrangedSubviews
            if index < arranged.count {
                if arranged[index] !== view {
                    if view.superview === stack {
                        stack.removeArrangedSubview(view)
                    }
                    stack.insertArrangedSubview(view, at: index)
                }
            } else {
                stack.addArrangedSubview(view)
            }
        }
        stack.addArrangedSubview(plus)
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

    private var selected = false
    private var hovering = false
    private var kind: TabKind = .web
    private var tracking: NSTrackingArea?
    private let badge = LetterBadgeView()
    private let mark = GlyphView()
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = TabCloseButton()
    private var closeWidth: NSLayoutConstraint?
    private var closeGap: NSLayoutConstraint?
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

        titleField.font = Theme.font(size: 12)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setAccessibilityElement(false)
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

        addSubview(badge)
        addSubview(mark)
        addSubview(imageView)
        addSubview(titleField)
        addSubview(closeButton)

        let width = closeButton.widthAnchor.constraint(equalToConstant: 0)
        let gap = titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: 0)
        closeWidth = width
        closeGap = gap
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MonoMetrics.tabPadding),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            badge.heightAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            mark.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            mark.heightAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            imageView.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            imageView.heightAnchor.constraint(equalToConstant: MonoMetrics.tabIcon),
            titleField.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: MonoMetrics.tabInnerGap),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    func apply(_ item: TabStripItem, index: Int) {
        selected = item.selected
        kind = item.kind
        toolTip = item.title
        badge.letter = item.badgeLetter
        badge.hex = item.badgeHex
        imageView.image = item.favicon
        titleField.font = item.kind == .terminal
            ? Theme.mono(size: MonoMetrics.terminalLabel)
            : Theme.font(size: MonoMetrics.tabLabel)
        titleField.stringValue = item.title
        titleField.textColor = item.selected ? Theme.text : Theme.mute
        closeButton.contentTintColor = item.selected ? Theme.text : Theme.mute
        if let glyph = item.glyph {
            mark.glyph = glyph
            mark.pointSize = MonoMetrics.tabIcon
            mark.tint = item.kind == .terminal ? Theme.termGlyph : (item.selected ? Theme.text : Theme.mute)
            mark.isHidden = false
            badge.isHidden = true
            imageView.isHidden = true
        } else {
            mark.isHidden = true
            let showImage = item.favicon != nil
            imageView.isHidden = !showImage
            badge.isHidden = showImage
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("app1.tab.\(index)")
        setAccessibilityLabel(item.accessibilityLabel ?? item.title)
        if let value = item.accessibilityValue {
            setAccessibilityValue(value)
        }
        if let help = item.accessibilityHelp {
            setAccessibilityHelp(help)
        }
        setAccessibilitySelected(item.selected)
        closeButton.setAccessibilityIdentifier("app1.tab.\(index).close")
        revealClose(item.selected || hovering)
        needsDisplay = true
    }

    override func accessibilityChildren() -> [Any]? {
        closeButton.isHidden ? [] : [closeButton]
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = Theme.tabPath(bounds, radius: MonoMetrics.tabRadius)
        if kind == .terminal {
            if selected {
                Theme.fillRaisedTab(top: Theme.termTabActive, bottom: Theme.termTab, path: path, in: bounds)
            } else {
                Theme.termTab.setFill()
                path.fill()
            }
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
                controller?.finishTabDrag(tabID: id, screenPoint: screen, cursorOffsetInTab: offset)
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

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        revealClose(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        revealClose(selected)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        titleField.textColor = selected ? Theme.text : Theme.mute
        mark.tint = kind == .terminal ? Theme.termGlyph : (selected ? Theme.text : Theme.mute)
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
