// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

enum BookmarkColumn {
    static let name = NSUserInterfaceItemIdentifier("name")
    static let address = NSUserInterfaceItemIdentifier("address")
}

@MainActor
final class BookmarksPageView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onOpen: ((Bookmark) -> Void)?
    var onImport: (() -> Void)?

    private let store: BookmarkStore
    private let sidebar = SidebarPanel()
    private let mainPanel = NSView()
    private let filterField = SearchField()
    private let searchField = SearchField()
    private let listStack = NSStackView()
    private let countChip = ChipLabel()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [Bookmark] = []
    private var selectedID: UUID?

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
        rebuildSidebar()
        rows = visibleBookmarks()
        countChip.text = rows.count == 1 ? "1 item" : "\(rows.count) items"
        table.reloadData()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sidebar.needsDisplay = true
        mainPanel.needsDisplay = true
        rebuildSidebar()
        table.reloadData()
    }

    private func build() {
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        mainPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sidebar)
        addSubview(mainPanel)

        filterField.configure(
            iconSize: 13,
            fontSize: 12,
            placeholder: "Filter bookmarks",
            placeholderSize: 12,
            radius: MonoMetrics.urlRadius
        )
        filterField.onTextChange = { [weak self] _ in self?.rebuildSidebar() }
        filterField.translatesAutoresizingMaskIntoConstraints = false

        let listDocument = FlippedDocumentView()
        listDocument.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.setContentHuggingPriority(.required, for: .vertical)
        listDocument.addSubview(listStack)

        let listScroll = NSScrollView()
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.documentView = listDocument
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(filterField)
        sidebar.addSubview(listScroll)

        let title = NSTextField(labelWithString: "Bookmarks")
        title.font = Theme.font(size: 24, weight: .semibold)
        title.textColor = Theme.text
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentHuggingPriority(.required, for: .horizontal)

        countChip.fontSize = 11
        countChip.translatesAutoresizingMaskIntoConstraints = false
        countChip.setContentHuggingPriority(.required, for: .horizontal)

        searchField.configure(
            iconSize: 13,
            fontSize: 13,
            placeholder: "Search bookmarks",
            placeholderSize: 13,
            radius: MonoMetrics.urlRadius
        )
        searchField.onTextChange = { [weak self] _ in self?.reloadTable() }
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: MonoMetrics.searchWidth)
        searchWidth.priority = NSLayoutConstraint.Priority(750)

        let importButton = NSButton(title: "Import Bookmarks…", target: self, action: #selector(importBookmarksTapped))
        importButton.bezelStyle = .rounded
        importButton.font = Theme.font(size: 13)
        importButton.setAccessibilityLabel("Import Bookmarks…")
        importButton.setAccessibilityIdentifier("wyvern.import.open")
        importButton.translatesAutoresizingMaskIntoConstraints = false

        let newFolder = AccentTextButton()
        newFolder.title = "New folder"
        newFolder.glyph = .plus
        newFolder.iconSize = 13
        newFolder.target = self
        newFolder.action = #selector(createFolder)
        newFolder.setAccessibilityLabel("New folder")
        newFolder.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [title, countChip, spacer, searchField, importButton, newFolder])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = MonoMetrics.headerGap
        header.translatesAutoresizingMaskIntoConstraints = false
        mainPanel.addSubview(header)

        configureTable()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        mainPanel.addSubview(scroll)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: MonoMetrics.sidebarWidth),
            mainPanel.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            mainPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainPanel.topAnchor.constraint(equalTo: topAnchor),
            mainPanel.bottomAnchor.constraint(equalTo: bottomAnchor),

            filterField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            filterField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            filterField.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            filterField.heightAnchor.constraint(equalToConstant: MonoMetrics.filterHeight),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            listScroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 6),
            listScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),

            listDocument.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
            listDocument.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            listDocument.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor),
            listStack.leadingAnchor.constraint(equalTo: listDocument.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listDocument.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listDocument.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: listDocument.bottomAnchor),

            header.leadingAnchor.constraint(equalTo: mainPanel.leadingAnchor, constant: MonoMetrics.pagePaddingH),
            header.trailingAnchor.constraint(equalTo: mainPanel.trailingAnchor, constant: -MonoMetrics.pagePaddingH),
            header.topAnchor.constraint(equalTo: mainPanel.topAnchor, constant: MonoMetrics.pagePaddingV),
            searchField.heightAnchor.constraint(equalToConstant: MonoMetrics.urlHeight),
            searchWidth,
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            newFolder.heightAnchor.constraint(equalToConstant: 28),
            importButton.heightAnchor.constraint(equalToConstant: 28),

            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: MonoMetrics.headerBottom),
            scroll.bottomAnchor.constraint(equalTo: mainPanel.bottomAnchor, constant: -MonoMetrics.pagePaddingV)
        ])
    }

    private func configureTable() {
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.headerView = NSTableHeaderView()
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.rowHeight = 34
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        addColumn("Name", id: BookmarkColumn.name, width: 360)
        addColumn("Address", id: BookmarkColumn.address, width: 320)

        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = table
    }

    private func addColumn(_ title: String, id: NSUserInterfaceItemIdentifier, width: CGFloat) {
        let column = NSTableColumn(identifier: id)
        let header = MonoHeaderCell(textCell: title)
        column.headerCell = header
        column.title = title
        column.width = width
        column.minWidth = 72
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
    }

    private func rebuildSidebar() {
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let query = filterField.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var isFirstVisibleGroup = true
        for group in store.groups() {
            let items = group.bookmarks.filter { query.isEmpty || matchesSidebar($0, query: query) }
            if group.isUnsorted && items.isEmpty { continue }
            if !query.isEmpty && items.isEmpty { continue }
            if !isFirstVisibleGroup {
                let rule = BookmarkGroupRule()
                rule.translatesAutoresizingMaskIntoConstraints = false
                listStack.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                rule.heightAnchor.constraint(equalToConstant: 13).isActive = true
            }
            isFirstVisibleGroup = false
            for bookmark in items {
                let row = BookmarkSidebarRow(bookmark: bookmark, selected: bookmark.id == selectedID)
                row.onOpen = { [weak self] in
                    self?.selectedID = bookmark.id
                    self?.onOpen?(bookmark)
                }
                row.onMenu = { [weak self] in
                    self?.menuFor(bookmark) ?? NSMenu()
                }
                listStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }
    }

    private func reloadTable() {
        rows = visibleBookmarks()
        countChip.text = rows.count == 1 ? "1 item" : "\(rows.count) items"
        table.reloadData()
    }

    private func visibleBookmarks() -> [Bookmark] {
        let query = searchField.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [Bookmark] = []
        for group in store.groups() {
            for bookmark in group.bookmarks where query.isEmpty || matchesTable(bookmark, query: query) {
                result.append(bookmark)
            }
        }
        return result
    }

    private func matchesSidebar(_ bookmark: Bookmark, query: String) -> Bool {
        bookmark.title.localizedCaseInsensitiveContains(query)
            || AddressFormatting.host(of: bookmark.url).localizedCaseInsensitiveContains(query)
    }

    private func matchesTable(_ bookmark: Bookmark, query: String) -> Bool {
        matchesSidebar(bookmark, query: query)
            || folderTitle(bookmark).localizedCaseInsensitiveContains(query)
    }

    private func folderTitle(_ bookmark: Bookmark) -> String {
        if let folder = bookmark.folder, store.folders.contains(folder) {
            return folder
        }
        return BookmarkStore.unsortedName
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = tableColumn else { return nil }
        let bookmark = rows[row]
        switch column.identifier {
        case BookmarkColumn.name:
            let cell = reused(BookmarkNameCell.self, id: column.identifier, in: tableView)
            cell.configure(title: bookmark.title)
            return cell
        case BookmarkColumn.address:
            let cell = reused(BookmarkTextCell.self, id: column.identifier, in: tableView)
            cell.configure(
                AddressFormatting.host(of: bookmark.url),
                font: Theme.mono(size: 12),
                color: Theme.mute
            )
            return cell
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("bookmark-row")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkLineRow
            ?? BookmarkLineRow()
        rowView.identifier = identifier
        return rowView
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.menu else { return }
        menu.removeAllItems()
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        appendActions(to: menu, bookmark: rows[row])
    }

    @objc private func tableClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        onOpen?(rows[row])
    }

    @objc private func importBookmarksTapped() {
        onImport?()
    }

    @objc private func createFolder() {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Name the folder."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.font = Theme.font(size: 13)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        guard store.addFolder(name: name) != nil else {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let rejected = NSAlert()
            rejected.messageText = "Folder name is reserved"
            rejected.informativeText = "Choose a name other than \(BookmarkStore.unsortedName)."
            rejected.addButton(withTitle: "OK")
            rejected.runModal()
            return
        }
        reload()
    }

    private func menuFor(_ bookmark: Bookmark) -> NSMenu {
        let menu = NSMenu()
        appendActions(to: menu, bookmark: bookmark)
        return menu
    }

    private func appendActions(to menu: NSMenu, bookmark: Bookmark) {
        let rename = NSMenuItem(title: "Rename", action: #selector(renameBookmark(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = bookmark.id.uuidString
        menu.addItem(rename)

        let remove = NSMenuItem(title: "Remove", action: #selector(removeBookmark(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = bookmark.id.uuidString
        menu.addItem(remove)

        let move = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(moveItem(title: BookmarkStore.unsortedName, bookmark: bookmark, folder: nil))
        for folder in store.folders {
            submenu.addItem(moveItem(title: folder, bookmark: bookmark, folder: folder))
        }
        move.submenu = submenu
        menu.addItem(move)
    }

    private func moveItem(title: String, bookmark: Bookmark, folder: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(moveBookmark(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = BookmarkMenuPayload(id: bookmark.id, folder: folder)
        return item
    }

    @objc private func renameBookmark(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let bookmark = store.bookmark(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Bookmark"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = bookmark.title
        field.font = Theme.font(size: 13)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.rename(id: id, title: field.stringValue)
        reload()
    }

    @objc private func removeBookmark(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        store.remove(id: id)
        reload()
    }

    @objc private func moveBookmark(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? BookmarkMenuPayload else { return }
        store.move(id: payload.id, toFolder: payload.folder)
        reload()
    }

    private func reused<View: NSView>(_ type: View.Type, id: NSUserInterfaceItemIdentifier, in tableView: NSTableView) -> View {
        if let cell = tableView.makeView(withIdentifier: id, owner: self) as? View {
            return cell
        }
        let cell = View(frame: .zero)
        cell.identifier = id
        return cell
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.page.setFill()
        bounds.fill()
    }
}

final class BookmarkMenuPayload: NSObject {
    let id: UUID
    let folder: String?

    init(id: UUID, folder: String?) {
        self.id = id
        self.folder = folder
    }
}

@MainActor
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class BookmarkGroupRule: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.line.setFill()
        let y = bounds.midY - 0.5
        NSRect(x: 8, y: y, width: max(0, bounds.width - 16), height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SidebarPanel: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.fillBarGradient(in: bounds)
        Theme.line.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class BookmarkSidebarRow: NSView {
    var onOpen: (() -> Void)?
    var onMenu: (() -> NSMenu)?
    private let selected: Bool
    private let badge = LetterBadgeView()
    private let titleField = NSTextField(labelWithString: "")

    init(bookmark: Bookmark, selected: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        badge.letter = SiteBadge.letter(forTitle: bookmark.title)
        badge.hex = SiteBadge.listHex
        badge.cornerRadius = MonoMetrics.faviconRadius
        badge.fontSize = 9
        badge.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = bookmark.title
        titleField.font = Theme.font(size: 12.5)
        titleField.textColor = Theme.text
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        addSubview(titleField)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: MonoMetrics.favicon),
            badge.heightAnchor.constraint(equalToConstant: MonoMetrics.favicon),
            titleField.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        Theme.tab.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        Theme.accent.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        onOpen?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?()
    }
}

@MainActor
final class BookmarkNameCell: NSTableCellView {
    private let badge = LetterBadgeView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        badge.cornerRadius = MonoMetrics.faviconRadius
        badge.fontSize = 9
        badge.hex = SiteBadge.listHex
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.font(size: 13)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        addSubview(label)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: MonoMetrics.favicon),
            badge.heightAnchor.constraint(equalToConstant: MonoMetrics.favicon),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        badge.letter = SiteBadge.letter(forTitle: title)
        label.stringValue = title
        label.textColor = Theme.text
    }
}

@MainActor
final class BookmarkTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ text: String, font: NSFont, color: NSColor) {
        label.stringValue = text
        label.font = font
        label.textColor = color
    }
}

@MainActor
final class BookmarkLineRow: NSTableRowView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.line.setFill()
        let y: CGFloat = isFlipped ? bounds.maxY - 1 : 0
        NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

@MainActor
final class MonoHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.page.setFill()
        cellFrame.fill()
        let rendered = NSAttributedString(string: stringValue.uppercased(), attributes: [
            .font: Theme.font(size: 11, weight: .semibold),
            .foregroundColor: Theme.mute,
            .kern: 11 * 0.05
        ])
        let size = rendered.size()
        let rect = NSRect(
            x: cellFrame.minX + 10,
            y: cellFrame.midY - size.height / 2,
            width: max(0, cellFrame.width - 20),
            height: size.height
        )
        rendered.draw(with: rect, options: [.usesLineFragmentOrigin])
        Theme.line.setFill()
        let lineY = controlView.isFlipped ? cellFrame.maxY - 1 : cellFrame.minY
        NSRect(x: cellFrame.minX, y: lineY, width: cellFrame.width, height: 1).fill()
    }
}
