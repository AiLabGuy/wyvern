// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

extension KVMKeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        let device = flags.intersection(.deviceIndependentFlagsMask)
        var value = KVMKeyModifiers()
        if device.contains(.command) { value.insert(.command) }
        if device.contains(.option) { value.insert(.option) }
        if device.contains(.control) { value.insert(.control) }
        if device.contains(.shift) { value.insert(.shift) }
        self = value
    }
}

/// Small address-bar pill. Active uses the blocked-count fill. Paused uses the stroked mute badge.
final class KVMAddressBadgeView: NSView {
    enum State: Equatable {
        case off
        case active
        case paused
    }

    private(set) var state: State = .off
    private(set) var preferredWidth: CGFloat = 0
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = true
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityIdentifier("wyvern.address.kvm")
        setAccessibilityElement(false)
        apply(.off)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func apply(_ state: State) {
        self.state = state
        let text: String
        let help: String
        switch state {
        case .off:
            text = ""
            help = ""
            label.stringValue = ""
        case .active:
            text = "KVM"
            help = "KVM mode. Control-Option-Command-K pauses key capture."
            label.font = Theme.mono(size: 10, weight: .semibold)
            label.textColor = .white
            label.stringValue = text
        case .paused:
            text = "KVM paused"
            help = "KVM paused. Control-Option-Command-K resumes key capture."
            label.font = Theme.font(size: 10, weight: .regular)
            label.textColor = Theme.mute
            label.stringValue = text
        }
        preferredWidth = Self.width(for: text, font: label.font ?? Theme.font(size: 10))
        toolTip = help.isEmpty ? nil : help
        setAccessibilityLabel(state == .off ? nil : text)
        setAccessibilityHelp(help.isEmpty ? nil : help)
        setAccessibilityElement(state != .off)
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: 18)
    }

    override func layout() {
        super.layout()
        let textHeight = label.cell?.cellSize.height ?? 12
        label.frame = NSRect(
            x: 8,
            y: (bounds.height - textHeight) / 2,
            width: max(0, bounds.width - 16),
            height: textHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard state != .off else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        switch state {
        case .active:
            Theme.blockTint.setFill()
            path.fill()
        case .paused:
            Theme.line.setStroke()
            path.lineWidth = 1
            path.stroke()
        case .off:
            break
        }
    }

    private static func width(for text: String, font: NSFont) -> CGFloat {
        guard text.isEmpty == false else { return 0 }
        let size = (text as NSString).size(withAttributes: [.font: font])
        // The label cell adds about 2 points of padding on each side, so leave room beyond the 8-point insets.
        return ceil(size.width) + 24
    }
}

/// Brief notice when Control-Option-Command-K flips capture for one tab.
@MainActor
enum KVMCaptureToast {
    private static var panel: KVMCaptureToastPanel?
    private static var hideTimer: Timer?

    static func show(_ text: String, in window: NSWindow?) {
        guard let host = window?.contentView else { return }
        let panel = panel ?? KVMCaptureToastPanel()
        self.panel = panel
        panel.present(text)
        if panel.superview !== host {
            panel.removeFromSuperview()
            host.addSubview(panel)
        }
        let width = min(420, max(220, host.bounds.width - 32))
        panel.frame = NSRect(x: (host.bounds.width - width) / 2, y: host.bounds.height - 52, width: width, height: 32)
        panel.isHidden = false
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 1.6, repeats: false) { _ in
            MainActor.assumeIsolated {
                panel.isHidden = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }
}

private final class KVMCaptureToastPanel: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = Theme.font(size: 12, weight: .medium)
        label.textColor = Theme.text
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityIdentifier("wyvern.address.kvm.toast")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(_ text: String) {
        label.stringValue = text
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        Theme.card.setFill()
        path.fill()
        Theme.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
