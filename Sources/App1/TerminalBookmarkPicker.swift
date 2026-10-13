// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import App1Core
import AppKit

/// Bookmark list for a new terminal tab. Drawn with Settings tokens so it does not use a system menu.
@MainActor
final class TerminalBookmarkPicker: NSView {
    private let scroll = NSScrollView()
    private let document = PickerDocument()
    private let stack = NSStackView()
    private var monitor: Any?
    private var onOpen: ((UUID) -> Void)?
    private weak var anchor: NSView?
    private var emptyNote: NSTextField?

    var isShown: Bool { superview != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("New Terminal Tab")
        setAccessibilityIdentifier("app1.terminal.picker")

        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.contentView.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityElement(false)

        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityElement(false)
        document.addSubview(stack)
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        func walk(_ view: NSView) {
            for subview in view.subviews {
                if subview is NSButton {
                    children.append(subview)
                }
                walk(subview)
            }
        }
        walk(self)
        if let emptyNote {
            children.append(emptyNote)
        }
        return children
    }

    func present(
        in host: NSView,
        anchor: NSView,
        bookmarks: [TerminalBookmark],
        onOpen: @escaping (UUID) -> Void
    ) {
        self.anchor = anchor
        self.onOpen = onOpen
        rebuild(bookmarks)
        translatesAutoresizingMaskIntoConstraints = true
        frame = NSRect(x: 0, y: 0, width: 360, height: 48)
        removeFromSuperview()
        host.addSubview(self)
        layoutSubtreeIfNeeded()
        // Sum the rows. The stack's own fitting size can collapse to the temporary frame.
        let gaps = stack.spacing * CGFloat(max(stack.arrangedSubviews.count - 1, 0))
        var stacked = gaps
        for view in stack.arrangedSubviews {
            stacked += view.fittingSize.height
        }
        let measured = max(stack.fittingSize.height, stacked) + 2
        let rows = CGFloat(max(bookmarks.count, 1))
        let estimated = 44 + rows * 56
        let contentHeight = measured > 40 ? measured : estimated
        place(anchor: anchor, in: host, height: min(max(contentHeight, 52), 420))
        installMonitor()
    }

    func dismiss() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        onOpen = nil
        anchor = nil
        removeFromSuperview()
    }

    private func rebuild(_ bookmarks: [TerminalBookmark]) {
        emptyNote = nil
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        stack.addArrangedSubview(pickerHeader("New Terminal Tab"))
        stack.addArrangedSubview(SettingsHairline())
        if bookmarks.isEmpty {
            stack.addArrangedSubview(paddedLine("No Terminal Bookmarks"))
        } else {
            for (index, bookmark) in bookmarks.enumerated() {
                if index > 0 {
                    stack.addArrangedSubview(SettingsHairline())
                }
                stack.addArrangedSubview(bookmarkRow(bookmark))
            }
        }
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func pickerHeader(_ text: String) -> NSView {
        let label = SettingsLabel(role: .headerTitle, text: text)
        label.setAccessibilityElement(false)
        return paddedLine(label, vertical: 12)
    }

    private func paddedLine(_ text: String) -> NSView {
        let label = SettingsLabel(role: .detail, text: text)
        label.setAccessibilityLabel(text)
        emptyNote = label
        return paddedLine(label, vertical: 14)
    }

    private func paddedLine(_ label: NSView, vertical: CGFloat) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: vertical),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -vertical),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
        return host
    }

    private func bookmarkRow(_ bookmark: TerminalBookmark) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.setAccessibilityElement(false)

        let glyph = GlyphView()
        glyph.glyph = .terminal
        glyph.tint = Theme.termGlyph
        glyph.pointSize = 14
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let name = SettingsLabel(role: .rowTitle, text: bookmark.name)
        name.lineBreakMode = .byTruncatingTail
        name.setAccessibilityElement(false)

        let command = NSTextField(labelWithString: bookmark.command)
        command.font = Theme.mono(size: 12)
        command.textColor = SettingsContrast.mute
        command.lineBreakMode = .byTruncatingMiddle
        command.maximumNumberOfLines = 1
        command.cell?.wraps = false
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        command.toolTip = bookmark.command
        command.setAccessibilityElement(false)

        let words = NSStackView()
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        words.translatesAutoresizingMaskIntoConstraints = false
        words.addArrangedSubview(name)
        words.addArrangedSubview(command)
        if !bookmark.workingDirectory.isEmpty {
            let directory = NSTextField(labelWithString: bookmark.workingDirectory)
            directory.font = Theme.mono(size: 11.5)
            directory.textColor = SettingsContrast.mute
            directory.lineBreakMode = .byTruncatingMiddle
            directory.maximumNumberOfLines = 1
            directory.cell?.wraps = false
            directory.toolTip = bookmark.workingDirectory
            directory.setAccessibilityElement(false)
            directory.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            words.addArrangedSubview(directory)
        }

        let open = DepthButton(title: "Open", kind: .secondary)
        styleSettingsButton(open)
        open.target = self
        open.action = #selector(openTapped(_:))
        open.identifier = NSUserInterfaceItemIdentifier(bookmark.id.uuidString)
        open.setAccessibilityLabel(bookmark.name)
        open.setAccessibilityTitle(bookmark.name)
        open.toolTip = bookmark.command

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let line = NSStackView(views: [glyph, words, spacer, open])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        line.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(line)
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.heightAnchor.constraint(equalToConstant: 16),
            line.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        return host
    }

    private func place(anchor: NSView, in host: NSView, height: CGFloat) {
        let anchorFrame = anchor.convert(anchor.bounds, to: host)
        let gap: CGFloat = 6
        let margin: CGFloat = 8
        // Stay under the button. Shrinking beats covering it, so a second right-click still hits the anchor.
        let available = anchorFrame.minY - gap - margin
        let fitted = min(height, max(available, 52))
        var x = anchorFrame.maxX - 360
        var y = anchorFrame.minY - gap - fitted
        if x < margin { x = margin }
        if x + 360 > host.bounds.width - margin {
            x = max(margin, host.bounds.width - 360 - margin)
        }
        if y < margin { y = margin }
        frame = NSRect(x: x, y: y, width: 360, height: fitted)
    }

    private func installMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return event }
                return self.handleMonitor(event)
            }
        }
    }

    private func handleMonitor(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.isEmpty, event.window === window else { return event }
            dismiss()
            return nil
        }
        guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return event }
        if event.window !== window {
            dismiss()
            return event
        }
        if let anchor, event.type == .rightMouseDown, event.window === anchor.window {
            let point = anchor.convert(event.locationInWindow, from: nil)
            if anchor.bounds.contains(point) {
                return event
            }
        }
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) {
            return event
        }
        dismiss()
        return event
    }

    @objc private func openTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        let open = onOpen
        dismiss()
        open?(id)
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = SettingsContrast.lineWidth
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2),
            xRadius: 10,
            yRadius: 10
        )
        Theme.card.setFill()
        path.fill()
        Theme.line.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class PickerDocument: NSView {
    override var isFlipped: Bool { true }
}
