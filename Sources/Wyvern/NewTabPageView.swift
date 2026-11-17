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
    private let tileScroll = NSScrollView()
    private let tileGrid = NSView()
    private var tileConstraints: [NSLayoutConstraint] = []
    private var gridHeight: NSLayoutConstraint?
    private var tilesByBookmark: [UUID: SiteTile] = [:]
    private var tileGeneration = 0
    private var bookmarkObserver: NSObjectProtocol?

    /// One tile's block: plate, gap under it, and a single-line title.
    private static let tileBlock = MonoMetrics.tileBox + 28

    var inputField: NSTextField { field.textField }

    init(store: BookmarkStore) {
        self.store = store
        super.init(frame: .zero)
        build()
        bookmarkObserver = NotificationCenter.default.addObserver(
            forName: .wyvernBookmarksDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
            }
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let bookmarkObserver {
            NotificationCenter.default.removeObserver(bookmarkObserver)
        }
    }

    func reload() {
        tileGeneration += 1
        let generation = tileGeneration
        NSLayoutConstraint.deactivate(tileConstraints)
        tileConstraints.removeAll()
        tilesByBookmark.removeAll()
        for view in tileGrid.subviews {
            view.removeFromSuperview()
        }

        let bookmarks = store.bookmarks
        tileScroll.isHidden = bookmarks.isEmpty
        guard !bookmarks.isEmpty else {
            gridHeight?.constant = 0
            return
        }

        let columns = columnCount
        for (index, bookmark) in bookmarks.enumerated() {
            let icon = immediateIcon(for: bookmark)
            let tile = SiteTile(
                title: bookmark.title,
                letter: SiteBadge.letter(forTitle: bookmark.title),
                hex: SiteBadge.colorHex(forHost: AddressFormatting.host(of: bookmark.url)),
                icon: icon
            )
            tile.onOpen = { [weak self] in self?.onOpen?(bookmark) }
            tile.setAccessibilityLabel(bookmark.title)
            tile.translatesAutoresizingMaskIntoConstraints = false
            tileGrid.addSubview(tile)
            tilesByBookmark[bookmark.id] = tile
            let columnIndex = index % columns
            let row = index / columns
            let x = CGFloat(columnIndex) * (MonoMetrics.tileWidth + MonoMetrics.tileGap)
            let y = CGFloat(row) * (Self.tileBlock + MonoMetrics.tileGap)
            tileConstraints.append(contentsOf: [
                tile.leadingAnchor.constraint(equalTo: tileGrid.leadingAnchor, constant: x),
                tile.topAnchor.constraint(equalTo: tileGrid.topAnchor, constant: y),
                tile.widthAnchor.constraint(equalToConstant: MonoMetrics.tileWidth)
            ])
            if icon == nil {
                scheduleFavicon(for: bookmark, generation: generation)
            }
        }
        let rows = (bookmarks.count + columns - 1) / columns
        let height = CGFloat(rows) * Self.tileBlock + CGFloat(max(0, rows - 1)) * MonoMetrics.tileGap
        gridHeight?.constant = height
        NSLayoutConstraint.activate(tileConstraints)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            reload()
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

    private var columnCount: Int {
        let stride = MonoMetrics.tileWidth + MonoMetrics.tileGap
        let usable = MonoMetrics.newTabFieldWidth + MonoMetrics.tileGap
        return max(1, Int(usable / stride))
    }

    private func immediateIcon(for bookmark: Bookmark) -> NSImage? {
        if let image = IconController.shared.image(forBookmark: bookmark.id) {
            return image
        }
        guard let url = URL(string: bookmark.url), let key = IconHostKey.normalize(url: url) else {
            return nil
        }
        return IconController.shared.image(forHost: key)
    }

    private func scheduleFavicon(for bookmark: Bookmark, generation: Int) {
        guard let page = URL(string: bookmark.url),
              let host = page.host,
              let iconURL = FaviconPolicy.fallback(host: host) else {
            return
        }
        let bookmarkID = bookmark.id
        Task { [weak self] in
            let image = await FaviconService.shared.image(for: iconURL)
            guard let self, self.tileGeneration == generation, let image else { return }
            self.tilesByBookmark[bookmarkID]?.setIcon(image)
        }
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
        field.suggestionProvider = { [weak self] text in
            guard let self else { return [] }
            return HistoryStore.shared.suggestions(matching: text, bookmarks: self.store.bookmarks)
        }
        field.onPickSuggestion = { [weak self] item in
            self?.onSubmit?(item.url)
        }
        field.translatesAutoresizingMaskIntoConstraints = false

        tileGrid.translatesAutoresizingMaskIntoConstraints = false
        tileScroll.translatesAutoresizingMaskIntoConstraints = false
        tileScroll.drawsBackground = false
        tileScroll.borderType = .noBorder
        tileScroll.hasVerticalScroller = true
        tileScroll.hasHorizontalScroller = false
        tileScroll.autohidesScrollers = true
        tileScroll.scrollerStyle = .overlay
        tileScroll.documentView = tileGrid
        let height = tileGrid.heightAnchor.constraint(equalToConstant: 0)
        gridHeight = height
        NSLayoutConstraint.activate([
            tileGrid.leadingAnchor.constraint(equalTo: tileScroll.contentView.leadingAnchor),
            tileGrid.trailingAnchor.constraint(equalTo: tileScroll.contentView.trailingAnchor),
            tileGrid.topAnchor.constraint(equalTo: tileScroll.contentView.topAnchor),
            tileGrid.widthAnchor.constraint(equalTo: tileScroll.contentView.widthAnchor),
            height
        ])

        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = MonoMetrics.columnGap
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(wordmark)
        column.addArrangedSubview(field)
        column.addArrangedSubview(tileScroll)
        addSubview(column)

        let scrollGrows = tileScroll.heightAnchor.constraint(equalTo: tileGrid.heightAnchor)
        scrollGrows.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            field.widthAnchor.constraint(equalToConstant: MonoMetrics.newTabFieldWidth),
            field.heightAnchor.constraint(equalToConstant: MonoMetrics.newTabFieldHeight),
            wordmark.widthAnchor.constraint(equalTo: field.widthAnchor),
            tileScroll.widthAnchor.constraint(equalTo: field.widthAnchor),
            scrollGrows,
            tileScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 360)
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

    private let badge = LetterBadgeView()
    private let iconView = NSImageView()

    init(title: String, letter: String, hex: String, icon: NSImage? = nil) {
        super.init(frame: .zero)
        let box = TilePlate()
        box.translatesAutoresizingMaskIntoConstraints = false
        badge.letter = letter
        badge.hex = hex
        badge.cornerRadius = MonoMetrics.tileBadgeRadius
        badge.fontSize = MonoMetrics.tileBadgeFont
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = icon != nil
        iconView.image = icon
        iconView.isHidden = icon == nil
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = MonoMetrics.tileBadgeRadius
        iconView.layer?.masksToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = Theme.font(size: 12)
        label.textColor = Theme.mute
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        box.addSubview(badge)
        box.addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.widthAnchor.constraint(equalToConstant: MonoMetrics.tileBox),
            box.heightAnchor.constraint(equalToConstant: MonoMetrics.tileBox),
            badge.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: MonoMetrics.tileBadge),
            badge.heightAnchor.constraint(equalToConstant: MonoMetrics.tileBadge),
            iconView.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            iconView.widthAnchor.constraint(equalTo: badge.widthAnchor),
            iconView.heightAnchor.constraint(equalTo: badge.heightAnchor),
            label.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func setIcon(_ image: NSImage?) {
        iconView.image = image
        let show = image != nil
        iconView.isHidden = !show
        badge.isHidden = show
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
