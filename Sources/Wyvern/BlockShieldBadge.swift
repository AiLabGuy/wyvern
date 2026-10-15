// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit

/// Toolbar blocked-count badge. Sits in the right-hand cluster, not in the address field.
@MainActor
final class BlockedCountBadge: NSButton {
    enum Look: Equatable {
        case active
        case zero
        case paused
        case disabled
    }

    var extraAccessibilityChild: NSView?
    private(set) var look: Look = .zero
    private(set) var preferredWidth: CGFloat = MonoMetrics.blockBadgeMinWidth
    private var count = 0
    private var hostName: String?
    private var hovered = false
    private let glyph = GlyphView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .shadowlessSquare
        setButtonType(.momentaryPushIn)
        imagePosition = .noImage
        focusRingType = .none
        wantsLayer = true
        glyph.pointSize = 12
        glyph.translatesAutoresizingMaskIntoConstraints = true
        label.translatesAutoresizingMaskIntoConstraints = true
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.alignment = .left
        label.setAccessibilityElement(false)
        label.wantsLayer = true
        addSubview(glyph)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("wyvern.toolbar.blocked")
        setAccessibilityElement(true)
        apply(count: 0, host: nil, look: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(count: Int, host: String?, look: Look) {
        let previous = label.stringValue
        self.count = count
        hostName = host
        self.look = look
        let text: String
        switch look {
        case .active:
            text = count > 99 ? "99+" : String(count)
            glyph.glyph = .shield
            glyph.tint = .white
            label.font = Theme.mono(size: 11, weight: .semibold)
            label.textColor = .white
            label.isHidden = false
        case .paused:
            text = "Paused"
            glyph.glyph = .pause
            glyph.tint = Theme.mute
            label.font = Theme.font(size: 10.5, weight: .regular)
            label.textColor = Theme.mute
            label.isHidden = false
        case .zero:
            text = ""
            glyph.glyph = .shield
            glyph.tint = Theme.mute
            label.isHidden = true
        case .disabled:
            text = ""
            glyph.glyph = .shieldSlash
            glyph.tint = Theme.mute
            label.isHidden = true
        }
        preferredWidth = Self.width(for: look, text: text)
        alphaValue = look == .disabled ? 0.55 : 1
        if label.stringValue != text {
            label.stringValue = text
            fadeCountIfNeeded(from: previous, to: text)
        }
        let exact = BlockListFormat.grouped(count)
        switch look {
        case .active:
            let items = count == 1 ? "item" : "items"
            setAccessibilityLabel("Blocked \(exact) \(items) on this page")
            toolTip = "\(exact) blocked on this page"
        case .zero:
            setAccessibilityLabel("Nothing blocked on this page")
            toolTip = "Nothing blocked on this page"
        case .paused:
            let place = host ?? "this site"
            setAccessibilityLabel("Blocking paused on \(place)")
            toolTip = "Blocking paused on \(place)"
        case .disabled:
            setAccessibilityLabel("Block list is off")
            toolTip = "Block list is off"
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: MonoMetrics.blockBadgeHeight)
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 12
        let showText = look == .active || look == .paused
        if showText {
            glyph.frame = NSRect(x: 8, y: (bounds.height - side) / 2, width: side, height: side)
            let textHeight = label.cell?.cellSize.height ?? 14
            let x = 8 + side + 4
            label.frame = NSRect(
                x: x,
                y: (bounds.height - textHeight) / 2,
                width: max(0, bounds.width - x - 8),
                height: textHeight
            )
        } else {
            glyph.frame = NSRect(
                x: (bounds.width - side) / 2,
                y: (bounds.height - side) / 2,
                width: side,
                height: side
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        return ok
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHidden == false else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func accessibilityChildren() -> [Any]? {
        guard let extraAccessibilityChild else { return super.accessibilityChildren() }
        var kids = super.accessibilityChildren() ?? []
        kids.append(extraAccessibilityChild)
        return kids
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        switch look {
        case .active:
            Theme.blockTint.setFill()
            path.fill()
            if isHighlighted {
                NSColor.black.withAlphaComponent(0.08).setFill()
                path.fill()
            } else if hovered {
                NSColor.white.withAlphaComponent(0.08).setFill()
                path.fill()
            }
        case .zero, .paused:
            if isHighlighted {
                Theme.field.withAlphaComponent(0.10).setFill()
                path.fill()
            } else if hovered {
                Theme.field.withAlphaComponent(0.06).setFill()
                path.fill()
            }
            Theme.line.setStroke()
            path.lineWidth = 1
            path.stroke()
        case .disabled:
            break
        }
        guard window?.firstResponder === self else { return }
        Theme.accent.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        ring.lineWidth = 2
        ring.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(count: count, host: hostName, look: look)
    }

    private func fadeCountIfNeeded(from previous: String, to text: String) {
        guard previous.isEmpty == false, text.isEmpty == false, previous != text else { return }
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else { return }
        label.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            self.label.animator().alphaValue = 1
        }
    }

    private static func width(for look: Look, text: String) -> CGFloat {
        switch look {
        case .zero, .disabled:
            return MonoMetrics.blockBadgeMinWidth
        case .active, .paused:
            let font: NSFont = look == .active
                ? Theme.mono(size: 11, weight: .semibold)
                : Theme.font(size: 10.5)
            let size = (text as NSString).size(withAttributes: [.font: font])
            return max(MonoMetrics.blockBadgeMinWidth, 8 + 12 + 4 + ceil(size.width) + 8)
        }
    }
}

/// Popover for the toolbar badge. Pause stays in sync with Allowed Sites.
@MainActor
final class BlockedCountPopoverController: NSViewController {
    var onPause: ((Bool) -> Void)?
    var onTurnOn: (() -> Void)?
    var onReload: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let glyph = GlyphView()
    private let header = NSTextField(wrappingLabelWithString: "")
    private let pauseCaption = NSTextField(labelWithString: "Pause on this site")
    private let pauseToggle = SettingsSwitch(label: "Pause on this site")
    private let pauseRow = NSStackView()
    private let turnOnButton = DepthButton(title: "Turn On Blocking", kind: .primary)
    private let reloadRow = NSStackView()
    private let settingsButton = ChevronLinkButton()
    private var applying = false
    private var showsReload = false
    private var blockingEnabled = false

    override func loadView() {
        let root = BlockedPanelRoot(frame: NSRect(x: 0, y: 0, width: MonoMetrics.blockPopoverWidth, height: 160))
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.popover)
        root.setAccessibilityLabel("Blocked content")
        root.setAccessibilityIdentifier("wyvern.toolbar.blocked.popover")

        glyph.pointSize = 16
        glyph.translatesAutoresizingMaskIntoConstraints = false
        header.font = Theme.font(size: 13, weight: .semibold)
        header.textColor = Theme.text
        header.maximumNumberOfLines = 3
        header.translatesAutoresizingMaskIntoConstraints = false
        let headerRow = NSStackView(views: [glyph, header])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        pauseCaption.font = Theme.font(size: 13)
        pauseCaption.textColor = Theme.text
        pauseCaption.setAccessibilityElement(false)
        pauseToggle.target = self
        pauseToggle.action = #selector(pauseToggled(_:))
        let pauseSpacer = NSView()
        pauseSpacer.translatesAutoresizingMaskIntoConstraints = false
        pauseSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        pauseRow.orientation = .horizontal
        pauseRow.alignment = .centerY
        pauseRow.spacing = 8
        pauseRow.translatesAutoresizingMaskIntoConstraints = false
        pauseRow.addArrangedSubview(pauseCaption)
        pauseRow.addArrangedSubview(pauseSpacer)
        pauseRow.addArrangedSubview(pauseToggle)

        styleSettingsButton(turnOnButton)
        turnOnButton.target = self
        turnOnButton.action = #selector(turnOnTapped)
        turnOnButton.translatesAutoresizingMaskIntoConstraints = false

        let reloadLabel = NSTextField(labelWithString: "Reload to apply ·")
        reloadLabel.font = Theme.font(size: 11.5)
        reloadLabel.textColor = SettingsContrast.mute
        let reloadLink = AccentLinkButton()
        reloadLink.linkTitle = "Reload"
        reloadLink.target = self
        reloadLink.action = #selector(reloadTapped)
        reloadLink.setAccessibilityLabel("Reload")
        reloadRow.orientation = .horizontal
        reloadRow.alignment = .centerY
        reloadRow.spacing = 4
        reloadRow.translatesAutoresizingMaskIntoConstraints = false
        reloadRow.addArrangedSubview(reloadLabel)
        reloadRow.addArrangedSubview(reloadLink)
        reloadRow.isHidden = true

        settingsButton.linkTitle = "Block List Settings…"
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.setAccessibilityLabel("Block List Settings")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        let lineTop = ThinSeparator()
        let lineBottom = ThinSeparator()
        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(lineTop)
        stack.addArrangedSubview(pauseRow)
        stack.addArrangedSubview(turnOnButton)
        stack.addArrangedSubview(reloadRow)
        stack.addArrangedSubview(lineBottom)
        stack.addArrangedSubview(settingsButton)
        stack.setCustomSpacing(8, after: lineTop)
        stack.setCustomSpacing(8, after: pauseRow)
        stack.setCustomSpacing(8, after: turnOnButton)
        stack.setCustomSpacing(8, after: reloadRow)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: MonoMetrics.blockPopoverWidth),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.heightAnchor.constraint(equalToConstant: 16),
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -24),
            pauseRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            turnOnButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            turnOnButton.heightAnchor.constraint(equalToConstant: 28),
            lineTop.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lineBottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settingsButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusInitial()
    }

    func resetTransient() {
        showsReload = false
        reloadRow.isHidden = true
    }

    func apply(host: String?, count: Int, blockingEnabled: Bool, paused: Bool, canPause: Bool) {
        self.blockingEnabled = blockingEnabled
        header.attributedStringValue = headerText(host: host, count: count, enabled: blockingEnabled)
        if blockingEnabled {
            glyph.glyph = .shield
            glyph.tint = count > 0 ? Theme.blockTint : Theme.mute
            pauseRow.isHidden = false
            turnOnButton.isHidden = true
            applying = true
            pauseToggle.state = paused ? .on : .off
            pauseToggle.isEnabled = canPause
            applying = false
            reloadRow.isHidden = showsReload == false
        } else {
            glyph.glyph = .shieldSlash
            glyph.tint = Theme.mute
            pauseRow.isHidden = true
            turnOnButton.isHidden = false
            reloadRow.isHidden = true
        }
        header.textColor = Theme.text
        pauseCaption.textColor = Theme.text
    }

    /// Shows "Reload to apply" after a pause or turn-on that should reload. A failure hides it.
    func noteUserChange(success: Bool) {
        showsReload = success
        if blockingEnabled {
            reloadRow.isHidden = success == false
        }
    }

    func focusInitial() {
        let target: NSView = blockingEnabled ? pauseToggle : turnOnButton
        view.window?.makeFirstResponder(target)
    }

    @objc private func pauseToggled(_ sender: NSSwitch) {
        guard applying == false else { return }
        onPause?(sender.state == .on)
    }

    @objc private func turnOnTapped() {
        onTurnOn?()
    }

    @objc private func reloadTapped() {
        onReload?()
    }

    @objc private func settingsTapped() {
        onOpenSettings?()
    }

    private func headerText(host: String?, count: Int, enabled: Bool) -> NSAttributedString {
        let semibold = Theme.font(size: 13, weight: .semibold)
        let ink = Theme.text
        if enabled == false {
            return NSAttributedString(string: "Block list is off", attributes: [
                .font: semibold,
                .foregroundColor: ink
            ])
        }
        let place = (host?.isEmpty == false) ? host! : "this page"
        if count <= 0 {
            return NSAttributedString(string: "Nothing blocked on \(place)", attributes: [
                .font: semibold,
                .foregroundColor: ink
            ])
        }
        let number = BlockListFormat.grouped(count)
        let result = NSMutableAttributedString(string: number, attributes: [
            .font: Theme.mono(size: 13, weight: .semibold),
            .foregroundColor: ink
        ])
        result.append(NSAttributedString(string: " blocked on \(place)", attributes: [
            .font: semibold,
            .foregroundColor: ink
        ]))
        return result
    }
}

@MainActor
private final class BlockedPanelRoot: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .popover }

    override func accessibilityLabel() -> String? { "Blocked content" }

    override func accessibilityChildren() -> [Any]? { subviews }

    private func apply() {
        layer?.backgroundColor = Theme.card.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
    }
}

@MainActor
private final class ThinSeparator: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.line.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Accent link with a trailing chevron, used by the blocked-count popover.
@MainActor
final class ChevronLinkButton: NSButton {
    var linkTitle = "" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 120, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = Theme.font(size: 13)
        let text = NSAttributedString(string: linkTitle, attributes: [
            .font: font,
            .foregroundColor: Theme.accent
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: 0, y: bounds.midY - size.height / 2))
        let chevron = NSAttributedString(string: "›", attributes: [
            .font: Theme.font(size: 14, weight: .semibold),
            .foregroundColor: Theme.accent
        ])
        let chevronSize = chevron.size()
        chevron.draw(at: NSPoint(x: bounds.width - chevronSize.width, y: bounds.midY - chevronSize.height / 2))
        guard window?.firstResponder === self else { return }
        Theme.accent.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        ring.lineWidth = 2
        ring.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
