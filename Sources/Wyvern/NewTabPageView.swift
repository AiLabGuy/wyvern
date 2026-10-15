// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

@MainActor
final class NewTabPageView: NSView {
    var onSubmit: ((String) -> Void)?
    var onOpen: ((Bookmark) -> Void)?

    private let store: BookmarkStore
    private let column = NSStackView()
    private let wordmark = NSTextField(labelWithString: "")
    private let field = SearchField()
    private let tiles = NSStackView()

    var inputField: NSTextField { field.textField }

    init(store: BookmarkStore) {
        self.store = store
        super.init(frame: .zero)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload() {
        for view in tiles.arrangedSubviews {
            tiles.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for bookmark in store.bookmarks.prefix(5) {
            let tile = SiteTile(
                title: bookmark.title,
                letter: SiteBadge.letter(forTitle: bookmark.title),
                hex: SiteBadge.colorHex(forHost: AddressFormatting.host(of: bookmark.url))
            )
            tile.onOpen = { [weak self] in self?.onOpen?(bookmark) }
            tile.translatesAutoresizingMaskIntoConstraints = false
            tiles.addArrangedSubview(tile)
            tile.widthAnchor.constraint(equalToConstant: MonoMetrics.tileWidth).isActive = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        applyWordmark()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.page.setFill()
        dirtyRect.fill()
    }

    private func build() {
        applyWordmark()
        wordmark.alignment = .center
        wordmark.translatesAutoresizingMaskIntoConstraints = false

        field.configure(
            iconSize: 16,
            fontSize: 15,
            placeholder: "Search or enter address",
            placeholderSize: 15,
            radius: MonoMetrics.newTabFieldRadius
        )
        field.textField.setAccessibilityIdentifier("wyvern.newtab.search")
        let shortcut = ChipLabel()
        shortcut.text = "⌘L"
        shortcut.monospaced = true
        shortcut.fontSize = 11
        field.setTrailingView(shortcut)
        field.onSubmit = { [weak self] text in self?.onSubmit?(text) }
        field.translatesAutoresizingMaskIntoConstraints = false

        tiles.orientation = .horizontal
        tiles.alignment = .top
        tiles.spacing = MonoMetrics.tileGap
        tiles.translatesAutoresizingMaskIntoConstraints = false

        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = MonoMetrics.columnGap
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(wordmark)
        column.addArrangedSubview(field)
        column.addArrangedSubview(tiles)
        addSubview(column)

        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            field.widthAnchor.constraint(equalToConstant: MonoMetrics.newTabFieldWidth),
            field.heightAnchor.constraint(equalToConstant: MonoMetrics.newTabFieldHeight),
            wordmark.widthAnchor.constraint(equalTo: field.widthAnchor)
        ])
    }

    private func applyWordmark() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        wordmark.attributedStringValue = NSAttributedString(string: AppInfo.displayName, attributes: [
            .font: Theme.font(size: 15, weight: .semibold),
            .foregroundColor: Theme.mute,
            .kern: 15 * 0.04,
            .paragraphStyle: style
        ])
    }
}

@MainActor
final class SiteTile: NSControl {
    var onOpen: (() -> Void)?

    init(title: String, letter: String, hex: String) {
        super.init(frame: .zero)
        let box = TilePlate()
        box.translatesAutoresizingMaskIntoConstraints = false
        let badge = LetterBadgeView()
        badge.letter = letter
        badge.hex = hex
        badge.cornerRadius = MonoMetrics.tileBadgeRadius
        badge.fontSize = MonoMetrics.tileBadgeFont
        badge.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = Theme.font(size: 12)
        label.textColor = Theme.mute
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        box.addSubview(badge)
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: MonoMetrics.tileWidth),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.widthAnchor.constraint(equalToConstant: MonoMetrics.tileBox),
            box.heightAnchor.constraint(equalToConstant: MonoMetrics.tileBox),
            badge.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: MonoMetrics.tileBadge),
            badge.heightAnchor.constraint(equalToConstant: MonoMetrics.tileBadge),
            label.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onOpen?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class TilePlate: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: MonoMetrics.urlRadius,
            yRadius: MonoMetrics.urlRadius
        )
        Theme.tab.setFill()
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
