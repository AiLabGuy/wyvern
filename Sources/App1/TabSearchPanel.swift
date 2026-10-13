// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import App1Core
import AppKit

struct TabSearchCandidate {
    var entry: TabSearchEntry
    var focus: () -> Void
}

/// Borderless palette. Up and Down move, Return switches, Escape closes.
@MainActor
final class TabSearchPanelController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    var candidates: () -> [TabSearchCandidate] = { [] }
    var onClose: (() -> Void)?
    private let field = NSTextField(frame: .zero)
    private let scroll = NSScrollView()
    private let list = NSView()
    private var rows: [TabSearchRow] = []
    private var matches: [TabSearchCandidate] = []
    private var selected = 0
    private var didClose = false

    init() {
        let panel = TabSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        build()
        panel.setAccessibilityIdentifier("app1.tabSearch")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPalette() {
        didClose = false
        field.stringValue = ""
        reload()
        guard let panel = window else { return }
        center(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func windowDidResignKey(_ notification: Notification) {
        closePalette()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let card = TabSearchCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(card)

        field.placeholderString = "Search tabs"
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.font(size: 15)
        field.textColor = Theme.text
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier("app1.tabSearch.field")
        field.setAccessibilityLabel("Search tabs")

        let fieldFrame = NSView()
        fieldFrame.translatesAutoresizingMaskIntoConstraints = false
        fieldFrame.wantsLayer = true
        fieldFrame.addSubview(field)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list

        content.addSubview(fieldFrame)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            card.topAnchor.constraint(equalTo: content.topAnchor),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            fieldFrame.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            fieldFrame.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            fieldFrame.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            fieldFrame.heightAnchor.constraint(equalToConstant: 36),
            field.leadingAnchor.constraint(equalTo: fieldFrame.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: fieldFrame.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: fieldFrame.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: fieldFrame.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closePalette()
            return true
        }
        return false
    }

    @objc private func submit() {
        guard matches.indices.contains(selected) else { return }
        let chosen = matches[selected]
        closePalette()
        chosen.focus()
    }

    private func moveSelection(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let next = min(max(selected + delta, 0), matches.count - 1)
        guard next != selected else { return }
        selected = next
        applySelection()
        scrollToSelected()
    }

    private func reload() {
        let all = candidates()
        let filtered = TabSearch.filter(all.map(\.entry), query: field.stringValue)
        matches = filtered.compactMap { entry in
            all.first { $0.entry.id == entry.id }
        }
        if selected >= matches.count {
            selected = 0
        }
        rebuildRows()
    }

    private func rebuildRows() {
        for subview in list.subviews {
            subview.removeFromSuperview()
        }
        rows.removeAll()
        var previous: NSView?
        if matches.isEmpty {
            let empty = NSTextField(labelWithString: "No matching tabs")
            empty.font = Theme.font(size: 13)
            empty.textColor = Theme.mute
            empty.translatesAutoresizingMaskIntoConstraints = false
            list.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 12),
                empty.topAnchor.constraint(equalTo: list.topAnchor, constant: 10),
                empty.bottomAnchor.constraint(equalTo: list.bottomAnchor, constant: -10)
            ])
            return
        }
        for (index, candidate) in matches.enumerated() {
            let row = TabSearchRow()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.title = candidate.entry.title.isEmpty ? "Untitled" : candidate.entry.title
            row.subtitle = candidate.entry.kind == .terminal ? candidate.entry.url : candidate.entry.url
            if candidate.entry.kind == .terminal && row.subtitle.isEmpty {
                row.subtitle = "Terminal"
            }
            row.kindLabel = candidate.entry.kind == .terminal ? "Terminal" : ""
            row.selected = index == selected
            row.setAccessibilityIdentifier("app1.tabSearch.row.\(index)")
            row.onClick = { [weak self] in
                self?.selected = index
                self?.submit()
            }
            list.addSubview(row)
            rows.append(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: list.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: list.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: 44)
            ])
            if let previous {
                row.topAnchor.constraint(equalTo: previous.bottomAnchor).isActive = true
            } else {
                row.topAnchor.constraint(equalTo: list.topAnchor).isActive = true
            }
            previous = row
        }
        previous?.bottomAnchor.constraint(equalTo: list.bottomAnchor).isActive = true
    }

    private func applySelection() {
        for (index, row) in rows.enumerated() {
            row.selected = index == selected
            row.needsDisplay = true
        }
    }

    private func scrollToSelected() {
        guard rows.indices.contains(selected) else { return }
        let row = rows[selected]
        scroll.contentView.scrollToVisible(row.frame)
    }

    private func center(_ panel: NSWindow) {
        let anchor = NSApp.keyWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.midY - size.height / 2 + 40
        ))
    }

    private func closePalette() {
        guard !didClose else { return }
        didClose = true
        window?.orderOut(nil)
        onClose?()
    }
}

private final class TabSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class TabSearchCard: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        Theme.card.setFill()
        path.fill()
        Theme.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class TabSearchRow: NSView {
    var title = ""
    var subtitle = ""
    var kindLabel = ""
    var selected = false
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            Theme.accentFill.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        let titleFont = Theme.font(size: 13, weight: .semibold)
        let titleText = NSAttributedString(string: title, attributes: [
            .font: titleFont,
            .foregroundColor: Theme.text
        ])
        titleText.draw(in: NSRect(x: 12, y: bounds.midY + 1, width: bounds.width - 24, height: 16))
        let secondary = kindLabel.isEmpty ? subtitle : "\(kindLabel) · \(subtitle)"
        let detail = NSAttributedString(string: secondary, attributes: [
            .font: Theme.font(size: 11),
            .foregroundColor: Theme.mute
        ])
        detail.draw(in: NSRect(x: 12, y: bounds.midY - 16, width: bounds.width - 24, height: 14))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
