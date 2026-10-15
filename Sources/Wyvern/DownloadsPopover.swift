// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

@MainActor
final class DownloadsPopoverController: NSViewController {
    private let list = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No downloads")
    private var rowViews: [DownloadRowView] = []

    override func loadView() {
        let root = DownloadsPanelView()
        root.setAccessibilityIdentifier("wyvern.downloads.popover")
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Downloads")

        let title = NSTextField(labelWithString: "Downloads")
        title.font = Theme.font(size: 13, weight: .semibold)
        title.textColor = Theme.text
        title.setAccessibilityElement(false)
        title.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearFinished))
        clear.isBordered = false
        clear.font = Theme.font(size: 11)
        clear.contentTintColor = Theme.mute
        clear.setAccessibilityLabel("Clear")
        clear.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Theme.font(size: 12)
        emptyLabel.textColor = Theme.mute
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(clear)
        root.addSubview(list)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 320),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            clear.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            clear.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            list.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            list.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            emptyLabel.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            emptyLabel.topAnchor.constraint(equalTo: list.topAnchor)
        ])
        view = root
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        for row in rowViews {
            list.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rowViews.removeAll()
        let items = DownloadManager.shared.items
        emptyLabel.isHidden = !items.isEmpty
        for (index, item) in items.enumerated() {
            let row = DownloadRowView(record: item, index: index)
            list.addArrangedSubview(row)
            rowViews.append(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: list.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: list.trailingAnchor)
            ])
        }
        preferredContentSize = NSSize(width: 320, height: max(72, 36 + CGFloat(max(items.count, 1)) * 52))
    }

    @objc private func clearFinished() {
        DownloadManager.shared.clearFinished()
        reload()
    }
}

@MainActor
final class DownloadsPanelView: NSView {
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

    private func apply() {
        layer?.backgroundColor = Theme.card.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
    }
}

@MainActor
final class DownloadRowView: NSView {
    private let record: DownloadRecord
    private let nameField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let badge = LetterBadgeView()
    private let bar = DownloadProgressBar()
    private let action = ToolButton()

    init(record: DownloadRecord, index: Int) {
        self.record = record
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("wyvern.download.row.\(index)")
        setAccessibilityLabel(record.filename)
        translatesAutoresizingMaskIntoConstraints = false

        badge.letter = SiteBadge.letter(forTitle: record.filename)
        badge.hex = SiteBadge.listHex
        badge.cornerRadius = MonoMetrics.faviconRadius
        badge.fontSize = 9
        badge.translatesAutoresizingMaskIntoConstraints = false

        nameField.stringValue = record.filename
        nameField.font = Theme.font(size: 12.5)
        nameField.textColor = Theme.text
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.setAccessibilityElement(false)

        statusField.font = Theme.font(size: 11)
        statusField.textColor = Theme.mute
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.setAccessibilityElement(false)

        bar.translatesAutoresizingMaskIntoConstraints = false

        action.pointSize = 12
        action.cornerRadius = 4
        action.tint = Theme.mute
        action.target = self
        action.action = #selector(tapped)
        action.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge)
        addSubview(nameField)
        addSubview(statusField)
        addSubview(bar)
        addSubview(action)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            badge.widthAnchor.constraint(equalToConstant: 14),
            badge.heightAnchor.constraint(equalToConstant: 14),
            nameField.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            nameField.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            nameField.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -8),
            statusField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            statusField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),
            statusField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            bar.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            bar.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 4),
            bar.heightAnchor.constraint(equalToConstant: 2),
            bar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            action.trailingAnchor.constraint(equalTo: trailingAnchor),
            action.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: 16),
            action.heightAnchor.constraint(equalToConstant: 16)
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        nameField.stringValue = record.filename
        statusField.stringValue = Self.statusLine(record)
        let active = record.state == .active
        bar.isHidden = !active
        bar.fraction = Self.fraction(record)
        if active {
            action.glyph = .close
            action.toolTip = "Cancel"
            action.setAccessibilityLabel("Cancel")
        } else {
            action.glyph = .folder
            action.toolTip = "Show in Finder"
            action.setAccessibilityLabel("Show in Finder")
            action.isHidden = record.finalURL == nil
        }
    }

    @objc private func tapped() {
        if record.state == .active {
            DownloadManager.shared.cancel(record)
            return
        }
        if let url = record.finalURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func fraction(_ record: DownloadRecord) -> CGFloat {
        guard record.total > 0 else { return 0 }
        return CGFloat(record.received) / CGFloat(record.total)
    }

    private static func statusLine(_ record: DownloadRecord) -> String {
        switch record.state {
        case .active:
            if record.total > 0 {
                return "\(bytes(record.received)) of \(bytes(record.total))"
            }
            return bytes(record.received)
        case .finished:
            let size = record.total > 0 ? record.total : record.received
            return "Done — \(bytes(size))"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    private static func bytes(_ value: Int64) -> String {
        if value < 1024 {
            return "\(value) B"
        }
        let kb = Double(value) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.1f GB", mb / 1024)
    }
}

@MainActor
final class DownloadProgressBar: NSView {
    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.line.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
        let width = bounds.width * min(max(fraction, 0), 1)
        guard width > 0 else { return }
        Theme.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: 1, yRadius: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
