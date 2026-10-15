// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// 14×14 `{}` tile. Dark and light fills follow the DevTools tab spec.
@MainActor
final class DevToolsBracesView: NSView {
    var pointSize: CGFloat = 14 {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height, pointSize)
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor
        let ring: NSColor
        let glyph: NSColor
        if dark {
            fill = Theme.card
            ring = Theme.accent.withAlphaComponent(0.55)
            glyph = Theme.accent
        } else {
            fill = Theme.color(hex: "#EEF2FD")
            ring = Theme.color(hex: "#2F5BEA", alpha: 0.45)
            glyph = Theme.color(hex: "#2F5BEA")
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        fill.setFill()
        path.fill()
        ring.setStroke()
        path.lineWidth = 1
        path.stroke()
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        let text = NSAttributedString(string: "{}", attributes: [
            .font: font,
            .foregroundColor: glyph
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Placeholder when the inspector stays in WebKit's detached window.
@MainActor
final class DevToolsWindowCard: NSView {
    var onShow: (() -> Void)?
    private let label = NSTextField(labelWithString: "Web Inspector is open in its own window ·")
    private let show = NSButton(title: "Show", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        label.font = Theme.font(size: 12, weight: .medium)
        label.textColor = Theme.text
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        show.target = self
        show.action = #selector(showTapped)
        show.isBordered = false
        show.font = Theme.font(size: 12, weight: .semibold)
        show.contentTintColor = Theme.accent
        show.setAccessibilityLabel("Show")
        show.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(show)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            show.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            show.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            show.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("Web Inspector is open in its own window")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        Theme.card.setFill()
        path.fill()
        Theme.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    @objc private func showTapped() {
        onShow?()
    }
}

/// "Linked to" chip. Click focuses the source tab.
@MainActor
final class DevToolsLinkedChip: NSControl {
    var onActivate: (() -> Void)?
    private let braces = DevToolsBracesView()
    private let prefix = NSTextField(labelWithString: "Linked to:")
    private let titleField = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        braces.pointSize = 14
        braces.translatesAutoresizingMaskIntoConstraints = false
        prefix.font = Theme.font(size: 11.5, weight: .regular)
        prefix.textColor = Theme.mute
        prefix.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = Theme.font(size: 11.5, weight: .regular)
        titleField.textColor = Theme.text
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(braces)
        addSubview(prefix)
        addSubview(titleField)
        let height = heightAnchor.constraint(equalToConstant: 24)
        let bracesLeading = braces.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        let bracesY = braces.centerYAnchor.constraint(equalTo: centerYAnchor)
        let bracesWidth = braces.widthAnchor.constraint(equalToConstant: 14)
        let bracesHeight = braces.heightAnchor.constraint(equalToConstant: 14)
        let prefixLeading = prefix.leadingAnchor.constraint(equalTo: braces.trailingAnchor, constant: 6)
        let prefixY = prefix.centerYAnchor.constraint(equalTo: centerYAnchor)
        let titleLeading = titleField.leadingAnchor.constraint(equalTo: prefix.trailingAnchor, constant: 4)
        let titleTrailing = titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        let titleY = titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        let titleCap = titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 220)
        // Horizontal pins yield when the toolbar forces the chip to zero width.
        for constraint in [bracesLeading, bracesWidth, prefixLeading, titleLeading, titleTrailing, titleCap] {
            constraint.priority = .defaultHigh
        }
        NSLayoutConstraint.activate([
            height, bracesLeading, bracesY, bracesWidth, bracesHeight,
            prefixLeading, prefixY, titleLeading, titleTrailing, titleY, titleCap
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Linked to")
        setAccessibilityIdentifier("wyvern.devtools.linked")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(title: String, url: String?) {
        if titleField.stringValue != title {
            titleField.stringValue = title
            needsDisplay = true
        }
        toolTip = url
        setAccessibilityLabel("Linked to \(title)")
        if let url {
            setAccessibilityHelp(url)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        Theme.card.setFill()
        path.fill()
        Theme.accent.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        prefix.textColor = Theme.mute
        titleField.textColor = Theme.text
        needsDisplay = true
    }
}

/// Partner hover: 1 px accent at 60% plus the hover fill. The view's alpha fades over 120 ms.
@MainActor
final class DevToolsPartnerRing: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let fill = NSBezierPath(roundedRect: bounds, xRadius: MonoMetrics.tabRadius, yRadius: MonoMetrics.tabRadius)
        Theme.highlight.setFill()
        fill.fill()
        let inset = bounds.insetBy(dx: 1, dy: 1)
        let ring = NSBezierPath(roundedRect: inset, xRadius: MonoMetrics.tabRadius, yRadius: MonoMetrics.tabRadius)
        Theme.accent.withAlphaComponent(0.6).setStroke()
        ring.lineWidth = 1
        ring.stroke()
    }
}

/// Link line between a source tab and its DevTools tab. Clicks pass through.
@MainActor
final class DevToolsLinkOverlay: NSView {
    struct Link: Equatable {
        var gapMidX: CGFloat
        var midY: CGFloat
        var leftEdgeX: CGFloat
        var rightEdgeX: CGFloat
    }

    var links: [Link] = [] {
        didSet {
            guard links != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let alpha: CGFloat = contrast ? 1 : 0.7
        Theme.accent.withAlphaComponent(alpha).setFill()
        for link in links {
            let bar = NSRect(x: link.gapMidX - 3, y: link.midY - 1, width: 6, height: 2)
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            NSBezierPath(ovalIn: NSRect(x: link.leftEdgeX - 2, y: link.midY - 2, width: 4, height: 4)).fill()
            NSBezierPath(ovalIn: NSRect(x: link.rightEdgeX - 2, y: link.midY - 2, width: 4, height: 4)).fill()
        }
    }
}

/// Top-center notice when a fourth pane is returned to the strip.
@MainActor
final class SplitFullToast: NSView {
    var onUndo: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let undo = NSButton(title: "Undo", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        label.font = Theme.font(size: 12, weight: .medium)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        undo.target = self
        undo.action = #selector(undoTapped)
        undo.isBordered = false
        undo.font = Theme.font(size: 12, weight: .semibold)
        undo.contentTintColor = Theme.accent
        undo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(undo)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            undo.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            undo.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            undo.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityIdentifier("wyvern.devtools.toast")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(title: String) {
        label.stringValue = "Split View is full — moved “\(title)” to a tab"
        setAccessibilityLabel(label.stringValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        Theme.card.setFill()
        path.fill()
        Theme.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    @objc private func undoTapped() {
        onUndo?()
    }
}

/// Sized, click-through view used as `_inspectorAttachmentView` before a DevTools tab exists.
@MainActor
final class DevToolsStandbyView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
