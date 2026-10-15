// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit

/// Settings → Block List. The window controller owns the observer token so `deinit` only
/// removes it and never calls back onto this main-actor type.
@MainActor
final class BlockListSettingsPane: NSObject, NSTextFieldDelegate {
    private weak var owner: SettingsWindowController?
    private var applying = false
    private var urlError: String?
    private var allowError: String?
    private var announcedCompile: String?
    private var awaitingUserUpdateFinish = false
    private var lastCheckedUntil: Date?
    private var lastCheckedGeneration = 0
    private var undoEntry: BlockListAllowEntry?
    private var undoGeneration = 0
    private var reloadNoteGeneration = 0
    private var listKeyViews: [NSView] = []
    private var removeKeyViews: [NSView] = []
    private var undoButton: NSButton?
    private var pendingAddURL: String?
    private var announcedRowErrors: Set<String> = []
    private weak var keyLoopAnchor: NSView?

    private let masterToggle = SettingsSwitch(label: "Block ads and trackers")
    private let metric = BlockListMetricLabel()
    private let reloadNoteHost = NSStackView()
    private let reloadAllButton = AccentLinkButton()
    private let listsLabel = SettingsLabel(role: .group, text: "Lists")
    private let listsSuffix = NSTextField(labelWithString: "")
    private let updateSpinner = NSProgressIndicator()
    private let updateButton = DepthButton(title: "Update Now", kind: .secondary)
    private let listStack = NSStackView()
    private let urlFrame = SettingsFieldFrame()
    private let urlErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let urlErrorHost = NSView()
    private let addListButton = DepthButton(title: "Add List", kind: .secondary)
    private let allowStack = NSStackView()
    private let searchField = BlockListSearchField()
    private let domainFrame = SettingsFieldFrame()
    private let allowErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let allowErrorHost = NSView()
    private let addAllowButton = DepthButton(title: "Add", kind: .secondary)
    private let compileNote = NSTextField(wrappingLabelWithString: "")
    private var listsHost: NSView?
    private var allowHost: NSView?

    func makeColumn(using owner: SettingsWindowController) -> NSStackView {
        self.owner = owner
        let column = owner.makeColumn()
        column.detachesHiddenViews = true
        let subtitle = owner.addSection(
            "Block List",
            id: "wyvern.settings.section.blockList",
            subtitle: "Block ads and trackers with filter lists. Pause on sites you trust.",
            to: column
        )

        masterToggle.target = self
        masterToggle.action = #selector(masterChanged(_:))
        masterToggle.setAccessibilityIdentifier("wyvern.settings.blockAds")
        let master = owner.makeCard(padded: false)
        owner.span(masterRow(), in: master.stack)
        owner.addCard(master.host, to: column)

        configureReloadNote()
        column.addArrangedSubview(reloadNoteHost)
        reloadNoteHost.isHidden = true

        let listsHeader = listsHeaderRow()
        column.addArrangedSubview(listsHeader)
        column.setCustomSpacing(SettingsLayout.groupTop, after: subtitle)
        column.setCustomSpacing(SettingsLayout.groupBottom, after: listsHeader)
        listsHeader.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        let lists = owner.makeCard(padded: false)
        listsHost = lists.host
        lists.stack.detachesHiddenViews = true
        configureListStack()
        lists.stack.addArrangedSubview(listStack)
        listStack.widthAnchor.constraint(equalTo: lists.stack.widthAnchor).isActive = true
        owner.span(SettingsHairline(), in: lists.stack)
        owner.span(addListRow(), in: lists.stack)
        configureError(urlErrorLabel, host: urlErrorHost)
        lists.stack.addArrangedSubview(urlErrorHost)
        urlErrorHost.widthAnchor.constraint(equalTo: lists.stack.widthAnchor).isActive = true
        urlErrorHost.isHidden = true
        owner.addCard(lists.host, to: column)

        owner.addGroup("Allowed sites", id: "wyvern.settings.blocklist.allowed", to: column, after: lists.host)
        let allowed = owner.makeCard(padded: false)
        allowHost = allowed.host
        allowed.stack.detachesHiddenViews = true
        owner.span(allowTopRow(), in: allowed.stack)
        configureError(allowErrorLabel, host: allowErrorHost)
        allowed.stack.addArrangedSubview(allowErrorHost)
        allowErrorHost.widthAnchor.constraint(equalTo: allowed.stack.widthAnchor).isActive = true
        allowErrorHost.isHidden = true
        configureAllowStack()
        allowed.stack.addArrangedSubview(allowStack)
        allowStack.widthAnchor.constraint(equalTo: allowed.stack.widthAnchor).isActive = true
        owner.addCard(allowed.host, to: column)

        compileNote.font = Theme.font(size: 11.5)
        compileNote.textColor = Theme.danger
        compileNote.maximumNumberOfLines = 4
        compileNote.isSelectable = false
        compileNote.isHidden = true
        compileNote.setAccessibilityIdentifier("wyvern.settings.blocklist.status")
        column.addArrangedSubview(compileNote)
        compileNote.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        reload(rulesChanged: false)
        return column
    }

    func reload(rulesChanged: Bool) {
        let focus = focusedToken()
        applying = true
        defer {
            applying = false
            restoreFocus(focus)
        }
        if rulesChanged {
            showReloadNote()
        }
        let controller = BlockListController.shared
        noteUpdateSettled(controller)
        masterToggle.state = controller.blockingEnabled ? .on : .off
        masterToggle.needsDisplay = true
        metric.phrase = masterPhrase(controller)
        let dim: CGFloat = controller.blockingEnabled ? 1 : 0.6
        listsHost?.alphaValue = dim
        allowHost?.alphaValue = dim
        reloadLists(controller)
        reloadAllow(controller)
        applyURLError()
        applyAllowError()
        applyCompile(controller)
        applySuffix(controller)
        applyUpdateButton(controller)
        syncPendingAdd(controller)
        announceRowErrors(controller)
        wireTabOrder()
    }

    /// Tab order from the sidebar row through the pane. The window turns automatic key-view
    /// calculation off while this pane is visible, so the chain is not overwritten.
    func attachKeyLoop(after anchor: NSView) {
        keyLoopAnchor = anchor
        wireTabOrder()
    }

    func detachKeyLoop() {
        keyLoopAnchor = nil
    }

    @objc private func masterChanged(_ sender: NSSwitch) {
        guard applying == false else { return }
        let on = sender.state == .on
        BlockListController.shared.setBlockingEnabled(on)
        if on == false {
            announce("Blocking is off", polite: false)
        }
        showReloadNote()
    }

    @objc private func listEnabledChanged(_ sender: NSSwitch) {
        guard applying == false else { return }
        guard let id = sender.identifier?.rawValue else { return }
        BlockListController.shared.setSourceEnabled(id, enabled: sender.state == .on)
        showReloadNote()
    }

    @objc private func updateNow() {
        awaitingUserUpdateFinish = true
        BlockListController.shared.update(force: true)
        reload(rulesChanged: false)
    }

    @objc private func addList() {
        guard applying == false, addListButton.isEnabled else { return }
        let raw = urlFrame.field.stringValue
        if let message = BlockListController.shared.addCustom(url: raw) {
            setURLError(message)
            return
        }
        if case .success(let normalized) = BlockListURL.check(raw) {
            pendingAddURL = normalized
        }
        setURLError(nil)
        reload(rulesChanged: false)
    }

    @objc private func addAllowedSite() {
        guard applying == false else { return }
        switch BlockListController.shared.addAllowed(domainFrame.field.stringValue) {
        case .added:
            domainFrame.field.stringValue = ""
            addAllowButton.isEnabled = false
            setAllowError(nil)
            showReloadNote()
            reload(rulesChanged: false)
        case .duplicate:
            setAllowError("Already allowed")
        case .invalid:
            break
        }
    }

    @objc private func removeAllowed(_ sender: NSButton) {
        guard let host = sender.identifier?.rawValue else { return }
        guard let entry = BlockListController.shared.removeAllowed(host: host) else { return }
        undoEntry = entry
        undoGeneration += 1
        let generation = undoGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { @MainActor in
                guard let self, self.undoGeneration == generation else { return }
                self.undoEntry = nil
                self.reload(rulesChanged: false)
            }
        }
        showReloadNote()
        reload(rulesChanged: false)
    }

    @objc private func undoRemove() {
        guard let entry = undoEntry else { return }
        undoEntry = nil
        undoGeneration += 1
        BlockListController.shared.restoreAllowed(entry)
        showReloadNote()
        reload(rulesChanged: false)
    }

    @objc private func retryList(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        BlockListController.shared.retry(id: id)
    }

    @objc private func showListMenu(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        guard let source = BlockListController.shared.snapshot.sources.first(where: { $0.id == id }) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, object: Any) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = object
            entry.isEnabled = true
            return entry
        }
        menu.addItem(item("Update Now", #selector(updateOne(_:)), object: id))
        menu.addItem(item("Copy URL", #selector(copyURL(_:)), object: source.urlString))
        menu.addItem(item("Rename…", #selector(renameList(_:)), object: id))
        menu.addItem(item("Remove", #selector(confirmRemoveList(_:)), object: id))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func updateOne(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        BlockListController.shared.retry(id: id)
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String, url.isEmpty == false else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(url, forType: .string)
    }

    @objc private func renameList(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let window = owner?.window else { return }
        guard let source = BlockListController.shared.snapshot.sources.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename list"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = source.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard response == .alertFirstButtonReturn else { return }
                BlockListController.shared.renameCustom(id: id, name: field.stringValue)
                self?.reload(rulesChanged: false)
            }
        }
    }

    @objc private func confirmRemoveList(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let window = owner?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove this list? Its rules stop applying."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard response == .alertSecondButtonReturn else { return }
                BlockListController.shared.removeCustom(id: id)
                self?.showReloadNote()
                self?.reload(rulesChanged: false)
            }
        }
    }

    @objc private func reloadAll() {
        for window in NSApp.windows {
            (window.windowController as? BrowserWindowController)?.reloadAllWebTabs()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === urlFrame.field {
            if let pendingAddURL {
                let same: Bool
                if case .success(let value) = BlockListURL.check(field.stringValue) {
                    same = value == pendingAddURL
                } else {
                    same = false
                }
                if same == false {
                    self.pendingAddURL = nil
                }
            }
            refreshURLField()
        } else if field === domainFrame.field {
            refreshAllowField()
        } else if field === searchField.field {
            reloadAllow(BlockListController.shared)
            wireTabOrder()
        }
    }

    private func masterPhrase(_ controller: BlockListController) -> String {
        if controller.blockingEnabled == false {
            return "Off — pages load everything"
        }
        let waiting = controller.snapshot.sources.contains { $0.enabled && $0.lastUpdated == nil }
        if waiting {
            return "Getting lists ready…"
        }
        let rules = BlockListFormat.grouped(controller.rulesActive)
        let week = BlockListFormat.grouped(controller.blockedThisWeek)
        return "\(rules) rules active · \(week) blocked this week"
    }

    private func reloadLists(_ controller: BlockListController) {
        clear(listStack)
        listKeyViews.removeAll()
        let sources = controller.snapshot.sources
        let noneOn = controller.blockingEnabled && sources.contains(where: \.enabled) == false
        if noneOn {
            let banner = bannerRow(
                "No lists are on, so nothing is blocked. Turn on a list below.",
                glyph: .shieldSlash
            )
            listStack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            if sources.isEmpty == false {
                appendHairline(in: listStack)
            }
        }
        for (index, source) in sources.enumerated() {
            if index > 0 || noneOn {
                if index > 0 {
                    appendHairline(in: listStack)
                }
            }
            let built = listRow(source, updating: controller.isUpdating)
            listStack.addArrangedSubview(built.view)
            built.view.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            listKeyViews.append(contentsOf: built.keys)
        }
    }

    private func reloadAllow(_ controller: BlockListController) {
        clear(allowStack)
        removeKeyViews.removeAll()
        undoButton = nil
        if let entry = undoEntry {
            let row = undoRow(entry.host)
            allowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: allowStack.widthAnchor).isActive = true
            appendHairline(in: allowStack)
        }
        let typed = searchField.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = typed.lowercased()
        let entries = controller.snapshot.allowlist.filter { needle.isEmpty || $0.host.contains(needle) }
        if controller.snapshot.allowlist.isEmpty && typed.isEmpty {
            if undoEntry == nil {
                let empty = centeredRow("No paused sites. Sites you pause from the toolbar appear here.", height: 48)
                allowStack.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: allowStack.widthAnchor).isActive = true
            }
            return
        }
        if entries.isEmpty {
            let miss = centeredRow("No allowed sites match \u{201C}\(typed)\u{201D}", height: 48)
            allowStack.addArrangedSubview(miss)
            miss.widthAnchor.constraint(equalTo: allowStack.widthAnchor).isActive = true
            return
        }
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                appendHairline(in: allowStack)
            }
            let built = allowRow(entry)
            allowStack.addArrangedSubview(built.view)
            built.view.widthAnchor.constraint(equalTo: allowStack.widthAnchor).isActive = true
            removeKeyViews.append(built.remove)
        }
    }

    private func listRow(_ source: BlockListSource, updating: Bool) -> (view: NSView, keys: [NSView]) {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let showSpinner = updating && source.enabled
        let failed = showSpinner == false && (source.lastError ?? "").isEmpty == false
        let icon = GlyphView()
        icon.pointSize = 16
        icon.translatesAutoresizingMaskIntoConstraints = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.translatesAutoresizingMaskIntoConstraints = false
        if showSpinner {
            icon.isHidden = true
            spinner.startAnimation(nil)
        } else if failed {
            icon.glyph = .warning
            icon.tint = Theme.danger
            spinner.isHidden = true
        } else if source.enabled {
            icon.glyph = .shield
            icon.tint = Theme.accent
            spinner.isHidden = true
        } else {
            icon.glyph = .shieldSlash
            icon.tint = Theme.mute
            spinner.isHidden = true
        }

        let name = SettingsLabel(role: .rowTitle, text: source.name)
        name.lineBreakMode = .byTruncatingTail
        let statusText = statusLine(source, updating: showSpinner)
        let status = NSTextField(labelWithString: statusText.text)
        status.font = Theme.font(size: 11.5)
        status.textColor = SettingsContrast.mute
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.toolTip = statusText.toolTip
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addArrangedSubview(status)
        var keys: [NSView] = []
        let toggle = SettingsSwitch(label: rowSentence(source, status: statusText.text))
        toggle.state = source.enabled ? .on : .off
        toggle.identifier = NSUserInterfaceItemIdentifier(source.id)
        toggle.target = self
        toggle.action = #selector(listEnabledChanged(_:))
        toggle.setAccessibilityIdentifier("wyvern.settings.blocklist.enabled.\(source.id)")
        keys.append(toggle)
        if let retryTitle = statusText.retry {
            let retry = AccentLinkButton()
            retry.linkTitle = retryTitle
            retry.target = self
            retry.action = #selector(retryList(_:))
            retry.identifier = NSUserInterfaceItemIdentifier(source.id)
            retry.setAccessibilityLabel("Retry \(source.name)")
            statusRow.addArrangedSubview(retry)
            keys.append(retry)
        }
        let words = NSStackView(views: [name, statusRow])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        words.translatesAutoresizingMaskIntoConstraints = false
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chip = RuleCountChip()
        if source.lastUpdated == nil {
            chip.text = "—"
            chip.setAccessibilityLabel("Unknown rules")
        } else {
            let grouped = BlockListFormat.grouped(source.domainCount)
            chip.text = grouped
            chip.setAccessibilityLabel("\(grouped) rules")
        }
        chip.setAccessibilityElement(true)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        var trailing: [NSView] = [chip, toggle]
        if source.isBuiltIn == false {
            let menu = NSButton()
            menu.title = "⋯"
            menu.isBordered = false
            menu.font = Theme.font(size: 16, weight: .semibold)
            menu.contentTintColor = Theme.mute
            menu.target = self
            menu.action = #selector(showListMenu(_:))
            menu.identifier = NSUserInterfaceItemIdentifier(source.id)
            menu.setAccessibilityLabel("More options for \(source.name)")
            menu.translatesAutoresizingMaskIntoConstraints = false
            menu.widthAnchor.constraint(equalToConstant: 22).isActive = true
            menu.heightAnchor.constraint(equalToConstant: 22).isActive = true
            trailing.append(menu)
            keys.append(menu)
        }
        let right = NSStackView(views: trailing)
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = 8
        right.setCustomSpacing(12, after: chip)
        right.translatesAutoresizingMaskIntoConstraints = false
        let line = NSStackView(views: [icon, spinner, words, spacer, right])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        line.detachesHiddenViews = true
        line.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(line)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.widthAnchor.constraint(equalToConstant: 10),
            spinner.heightAnchor.constraint(equalToConstant: 10),
            line.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
        ])
        return (host, keys)
    }

    private func statusLine(_ source: BlockListSource, updating: Bool) -> (text: String, toolTip: String?, retry: String?) {
        if updating {
            let text = source.lastUpdated == nil ? "Downloading…" : "Updating…"
            return (text, nil, nil)
        }
        if let error = source.lastError, error.isEmpty == false {
            var text = "Couldn't update: \(error)"
            var tip: String?
            if let date = source.lastUpdated {
                text += " · Using copy from \(BlockListDates.monthDay(date))"
                tip = BlockListDates.absolute(date)
            }
            return (text, tip, "Retry")
        }
        if let date = source.lastUpdated {
            let text = "Updated \(BlockListRelativeTime.phrase(since: date, now: Date()))"
            return (text, BlockListDates.absolute(date), nil)
        }
        return ("Not downloaded · turn on to download", nil, nil)
    }

    private func rowSentence(_ source: BlockListSource, status: String) -> String {
        let name = source.name
            .replacingOccurrences(of: " (", with: ", ")
            .replacingOccurrences(of: ")", with: "")
        let state = source.enabled ? "on" : "off"
        let rules: String
        if source.lastUpdated == nil {
            rules = "unknown rules"
        } else {
            rules = "\(BlockListFormat.grouped(source.domainCount)) rules"
        }
        let detail = status.prefix(1).lowercased() + status.dropFirst()
        return "\(name), \(state), \(rules), \(detail)"
    }

    private func allowRow(_ entry: BlockListAllowEntry) -> (view: NSView, remove: NSButton) {
        let host = BlockListAllowRow()
        host.translatesAutoresizingMaskIntoConstraints = false
        let icon = GlyphView()
        icon.glyph = .pause
        icon.tint = Theme.mute
        icon.pointSize = 16
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: entry.host)
        name.font = Theme.mono(size: 13)
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let meta = NSTextField(labelWithString: "Paused · added \(BlockListDates.monthDay(entry.added))")
        meta.font = Theme.font(size: 11.5)
        meta.textColor = SettingsContrast.mute
        meta.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let remove = host.removeButton
        remove.target = self
        remove.action = #selector(removeAllowed(_:))
        remove.identifier = NSUserInterfaceItemIdentifier(entry.host)
        remove.setAccessibilityLabel("Remove \(entry.host)")
        let line = NSStackView(views: [icon, name, spacer, meta, remove])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        line.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(line)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            remove.widthAnchor.constraint(equalToConstant: 18),
            remove.heightAnchor.constraint(equalToConstant: 18),
            line.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: host.topAnchor),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.heightAnchor.constraint(equalToConstant: 40)
        ])
        host.refreshRemove()
        return (host, remove)
    }

    private func undoRow(_ hostName: String) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "Removed \(hostName) ·")
        label.font = Theme.font(size: 11.5)
        label.textColor = SettingsContrast.mute
        let undo = AccentLinkButton()
        undo.linkTitle = "Undo"
        undo.target = self
        undo.action = #selector(undoRemove)
        undo.setAccessibilityLabel("Undo")
        undoButton = undo
        let row = NSStackView(views: [label, undo])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            host.heightAnchor.constraint(equalToConstant: 32)
        ])
        return host
    }

    private func masterRow() -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let title = SettingsLabel(role: .rowTitle, text: "Block ads and trackers")
        let words = NSStackView(views: [title, metric])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        words.translatesAutoresizingMaskIntoConstraints = false
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let line = NSStackView(views: [words, spacer, masterToggle])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 12
        line.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        return host
    }

    private func listsHeaderRow() -> NSView {
        listsSuffix.font = Theme.font(size: 11)
        listsSuffix.textColor = SettingsContrast.mute
        listsSuffix.lineBreakMode = .byTruncatingTail
        listsSuffix.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        listsSuffix.isHidden = true
        updateSpinner.style = .spinning
        updateSpinner.controlSize = .small
        updateSpinner.translatesAutoresizingMaskIntoConstraints = false
        updateSpinner.isHidden = true
        styleSettingsButton(updateButton)
        updateButton.target = self
        updateButton.action = #selector(updateNow)
        updateButton.setAccessibilityIdentifier("wyvern.settings.blocklist.update")
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [listsLabel, listsSuffix, spacer, updateSpinner, updateButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        updateSpinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
        updateSpinner.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return row
    }

    private func addListRow() -> NSView {
        let field = urlFrame.field
        field.placeholderString = "https://example.org/filters.txt"
        field.delegate = self
        field.target = self
        field.action = #selector(addList)
        if let cell = field.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = false
        }
        field.setAccessibilityIdentifier("wyvern.settings.blocklist.url")
        field.setAccessibilityLabel("List URL")
        urlFrame.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlFrame.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        styleSettingsButton(addListButton)
        addListButton.target = self
        addListButton.action = #selector(addList)
        addListButton.isEnabled = false
        addListButton.setAccessibilityIdentifier("wyvern.settings.blocklist.add")
        let row = NSStackView(views: [urlFrame, addListButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            urlFrame.heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8)
        ])
        return host
    }

    private func allowTopRow() -> NSView {
        searchField.field.delegate = self
        searchField.setAccessibilityIdentifier("wyvern.settings.blocklist.search")
        domainFrame.field.placeholderString = "example.com"
        domainFrame.field.delegate = self
        domainFrame.field.target = self
        domainFrame.field.action = #selector(addAllowedSite)
        if let cell = domainFrame.field.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = false
        }
        domainFrame.field.setAccessibilityIdentifier("wyvern.settings.blocklist.allow")
        domainFrame.field.setAccessibilityLabel("Allowed site")
        styleSettingsButton(addAllowButton)
        addAllowButton.target = self
        addAllowButton.action = #selector(addAllowedSite)
        addAllowButton.isEnabled = false
        addAllowButton.setAccessibilityIdentifier("wyvern.settings.blocklist.allow.add")
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [searchField, spacer, domainFrame, addAllowButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            searchField.widthAnchor.constraint(equalToConstant: 200),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            domainFrame.widthAnchor.constraint(equalToConstant: 180),
            domainFrame.heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8)
        ])
        return host
    }

    private func configureReloadNote() {
        let label = NSTextField(labelWithString: "Reload pages to apply")
        label.font = Theme.font(size: 11.5)
        label.textColor = SettingsContrast.mute
        let dot = NSTextField(labelWithString: "·")
        dot.font = Theme.font(size: 11.5)
        dot.textColor = SettingsContrast.mute
        reloadAllButton.linkTitle = "Reload All"
        reloadAllButton.target = self
        reloadAllButton.action = #selector(reloadAll)
        reloadAllButton.setAccessibilityLabel("Reload All")
        reloadNoteHost.orientation = .horizontal
        reloadNoteHost.alignment = .centerY
        reloadNoteHost.spacing = 4
        reloadNoteHost.translatesAutoresizingMaskIntoConstraints = false
        reloadNoteHost.addArrangedSubview(label)
        reloadNoteHost.addArrangedSubview(dot)
        reloadNoteHost.addArrangedSubview(reloadAllButton)
    }

    private func configureListStack() {
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.setAccessibilityIdentifier("wyvern.settings.blocklists")
    }

    private func configureAllowStack() {
        allowStack.orientation = .vertical
        allowStack.alignment = .leading
        allowStack.spacing = 0
        allowStack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureError(_ label: NSTextField, host: NSView) {
        label.font = Theme.font(size: 11.5)
        label.textColor = Theme.danger
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8)
        ])
    }

    private func showReloadNote() {
        reloadNoteHost.isHidden = false
        reloadNoteGeneration += 1
        let generation = reloadNoteGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            Task { @MainActor in
                guard let self, self.reloadNoteGeneration == generation else { return }
                self.reloadNoteHost.isHidden = true
            }
        }
    }

    private func noteUpdateSettled(_ controller: BlockListController) {
        guard awaitingUserUpdateFinish, controller.isUpdating == false else { return }
        awaitingUserUpdateFinish = false
        lastCheckedUntil = Date().addingTimeInterval(10)
        lastCheckedGeneration += 1
        let generation = lastCheckedGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { @MainActor in
                guard let self, self.lastCheckedGeneration == generation else { return }
                self.lastCheckedUntil = nil
                self.reload(rulesChanged: false)
            }
        }
    }

    private func applyUpdateButton(_ controller: BlockListController) {
        if controller.isUpdating {
            updateButton.title = "Updating…"
            updateButton.isEnabled = false
            updateSpinner.isHidden = false
            updateSpinner.startAnimation(nil)
        } else {
            updateButton.title = "Update Now"
            updateButton.isEnabled = true
            updateSpinner.isHidden = true
            updateSpinner.stopAnimation(nil)
        }
        updateButton.invalidateIntrinsicContentSize()
    }

    private func applySuffix(_ controller: BlockListController) {
        let enabled = controller.snapshot.sources.filter(\.enabled)
        let allFailed = controller.isUpdating == false
            && enabled.isEmpty == false
            && enabled.allSatisfy { ($0.lastError ?? "").isEmpty == false }
        if allFailed {
            listsSuffix.stringValue = "⚠ Couldn't reach list servers — using saved copies"
            listsSuffix.textColor = Theme.danger
            listsSuffix.isHidden = false
            return
        }
        if let until = lastCheckedUntil, until > Date(), controller.isUpdating == false {
            listsSuffix.stringValue = "Last checked just now"
            listsSuffix.textColor = SettingsContrast.mute
            listsSuffix.isHidden = false
            return
        }
        listsSuffix.stringValue = ""
        listsSuffix.isHidden = true
    }

    private func applyCompile(_ controller: BlockListController) {
        let message = controller.snapshot.compileError ?? ""
        if message.isEmpty {
            compileNote.isHidden = true
            compileNote.stringValue = ""
            announcedCompile = nil
            return
        }
        compileNote.stringValue = message
        compileNote.textColor = Theme.danger
        compileNote.isHidden = false
        guard message != announcedCompile else { return }
        announcedCompile = message
        announce(message, polite: true)
    }

    private func refreshURLField() {
        switch BlockListURL.check(urlFrame.field.stringValue) {
        case .success:
            addListButton.isEnabled = true
            setURLError(nil)
        case .failure(.needsHTTPS):
            addListButton.isEnabled = false
            setURLError("Use an https:// address")
        case .failure:
            addListButton.isEnabled = false
            setURLError(nil)
        }
    }

    private func refreshAllowField() {
        addAllowButton.isEnabled = BlockListAllowlist.normalize(domainFrame.field.stringValue) != nil
        setAllowError(nil)
    }

    private func setURLError(_ message: String?) {
        guard urlError != message else { return }
        urlError = message
        applyURLError()
        if let message {
            announce(message, polite: true)
        }
    }

    private func setAllowError(_ message: String?) {
        guard allowError != message else { return }
        allowError = message
        applyAllowError()
        if let message {
            announce(message, polite: true)
        }
    }

    private func applyURLError() {
        if let urlError {
            urlErrorLabel.stringValue = "⚠ \(urlError)"
            urlErrorLabel.textColor = Theme.danger
            urlErrorHost.isHidden = false
        } else {
            urlErrorLabel.stringValue = ""
            urlErrorHost.isHidden = true
        }
    }

    private func applyAllowError() {
        if let allowError {
            allowErrorLabel.stringValue = "⚠ \(allowError)"
            allowErrorLabel.textColor = Theme.danger
            allowErrorHost.isHidden = false
        } else {
            allowErrorLabel.stringValue = ""
            allowErrorHost.isHidden = true
        }
    }

    private func syncPendingAdd(_ controller: BlockListController) {
        guard let pendingAddURL else { return }
        guard let source = controller.snapshot.sources.first(where: { $0.urlString == pendingAddURL }) else { return }
        if let error = source.lastError, error.isEmpty == false {
            setURLError(error)
            return
        }
        guard source.lastUpdated != nil else { return }
        if case .success(let value) = BlockListURL.check(urlFrame.field.stringValue), value == pendingAddURL {
            urlFrame.field.stringValue = ""
            addListButton.isEnabled = false
        }
        self.pendingAddURL = nil
        setURLError(nil)
    }

    private func announceRowErrors(_ controller: BlockListController) {
        var live: Set<String> = []
        for source in controller.snapshot.sources {
            guard let error = source.lastError, error.isEmpty == false else { continue }
            let key = source.id + "\n" + error
            live.insert(key)
            if source.urlString == pendingAddURL { continue }
            guard announcedRowErrors.contains(key) == false else { continue }
            announce("Couldn't update: \(error)", polite: true)
        }
        announcedRowErrors = live
    }

    private func announce(_ text: String, polite: Bool) {
        guard let element = owner?.window else { return }
        var info: [NSAccessibility.NotificationUserInfoKey: Any] = [.announcement: text]
        if polite {
            info[.priority] = NSNumber(value: NSAccessibilityPriorityLevel.low.rawValue)
        }
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: info)
    }

    private func wireTabOrder() {
        var chain: [NSView] = [masterToggle]
        if reloadNoteHost.isHidden == false {
            chain.append(reloadAllButton)
        }
        chain.append(updateButton)
        chain.append(contentsOf: listKeyViews)
        chain.append(urlFrame.field)
        chain.append(addListButton)
        chain.append(searchField.field)
        chain.append(domainFrame.field)
        chain.append(addAllowButton)
        if let undoButton, undoEntry != nil {
            chain.append(undoButton)
        }
        chain.append(contentsOf: removeKeyViews)
        for index in chain.indices.dropLast() {
            chain[index].nextKeyView = chain[index + 1]
        }
        if let anchor = keyLoopAnchor, let first = chain.first {
            anchor.nextKeyView = first
            chain.last?.nextKeyView = anchor
        }
    }

    /// Identity of the focused control. Rows are rebuilt on reload, so the switch would
    /// otherwise resign and the next Tab would start over.
    private func focusedToken() -> String? {
        guard let view = owner?.window?.firstResponder as? NSView else { return nil }
        if view === masterToggle { return "master" }
        if view === updateButton { return "update" }
        if view === urlFrame.field || (urlFrame.field.currentEditor() as NSView?) === view { return "url" }
        if view === addListButton { return "add-list" }
        if view === searchField.field || (searchField.field.currentEditor() as NSView?) === view { return "search" }
        if view === domainFrame.field || (domainFrame.field.currentEditor() as NSView?) === view { return "domain" }
        if view === addAllowButton { return "add-allow" }
        if view === undoButton { return "undo" }
        guard let control = view as? NSControl, let raw = control.identifier?.rawValue, raw.isEmpty == false else {
            return nil
        }
        let kind: String
        if control.action == #selector(listEnabledChanged(_:)) {
            kind = "toggle"
        } else if control.action == #selector(retryList(_:)) {
            kind = "retry"
        } else if control.action == #selector(showListMenu(_:)) {
            kind = "menu"
        } else if control.action == #selector(removeAllowed(_:)) {
            kind = "remove"
        } else {
            return nil
        }
        return "\(kind):\(raw)"
    }

    private func restoreFocus(_ token: String?) {
        guard let token, let window = owner?.window else { return }
        if let responder = window.firstResponder as? NSView, responder !== window {
            return
        }
        let next: NSView?
        switch token {
        case "master": next = masterToggle
        case "update": next = updateButton
        case "url": next = urlFrame.field
        case "add-list": next = addListButton
        case "search": next = searchField.field
        case "domain": next = domainFrame.field
        case "add-allow": next = addAllowButton
        case "undo": next = undoButton
        default: next = viewMatching(token)
        }
        guard let next else { return }
        window.makeFirstResponder(next)
    }

    private func viewMatching(_ token: String) -> NSView? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let matches = (listKeyViews + removeKeyViews).compactMap { $0 as? NSControl }
        return matches.first { control in
            guard control.identifier?.rawValue == parts[1] else { return false }
            switch parts[0] {
            case "toggle": return control.action == #selector(listEnabledChanged(_:))
            case "retry": return control.action == #selector(retryList(_:))
            case "menu": return control.action == #selector(showListMenu(_:))
            case "remove": return control.action == #selector(removeAllowed(_:))
            default: return false
            }
        }
    }

    private func bannerRow(_ text: String, glyph: IconGlyph) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let icon = GlyphView()
        icon.glyph = glyph
        icon.tint = Theme.mute
        icon.pointSize = 16
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.font(size: 12.5)
        label.textColor = SettingsContrast.mute
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(icon)
        host.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        return host
    }

    private func centeredRow(_ text: String, height: CGFloat) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.font(size: 12)
        label.textColor = SettingsContrast.mute
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            host.heightAnchor.constraint(equalToConstant: height)
        ])
        return host
    }

    private func appendHairline(in stack: NSStackView) {
        let line = SettingsHairline()
        line.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

@MainActor
private final class BlockListMetricLabel: NSTextField {
    var phrase = "" {
        didSet { redraw() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        isBordered = false
        backgroundColor = .clear
        maximumNumberOfLines = 2
        cell?.wraps = true
        lineBreakMode = .byWordWrapping
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds.width > 40 else { return }
        if abs(preferredMaxLayoutWidth - bounds.width) > 2 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    private func redraw() {
        let base = Theme.font(size: 11.5)
        let mono = Theme.mono(size: 11.5)
        let ink = SettingsContrast.mute
        let result = NSMutableAttributedString()
        var number = ""
        func flushNumber() {
            guard number.isEmpty == false else { return }
            result.append(NSAttributedString(string: number, attributes: [
                .font: mono,
                .foregroundColor: ink
            ]))
            number = ""
        }
        for character in phrase {
            if character.isNumber || character == "," {
                number.append(character)
            } else {
                flushNumber()
                result.append(NSAttributedString(string: String(character), attributes: [
                    .font: base,
                    .foregroundColor: ink
                ]))
            }
        }
        flushNumber()
        attributedStringValue = result
    }
}

@MainActor
private final class RuleCountChip: NSView {
    var text = "—" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        let font = Theme.mono(size: 11)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: max(44, ceil(size.width) + 16), height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.field.setFill()
        path.fill()
        Theme.fieldLine.setStroke()
        path.lineWidth = 1
        path.stroke()
        let font = Theme.mono(size: 11)
        let rendered = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: Theme.mute
        ])
        let size = rendered.size()
        let rect = NSRect(
            x: bounds.width - 8 - size.width,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        rendered.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class AccentLinkButton: NSButton {
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
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let font = Theme.font(size: 11.5)
        let size = (linkTitle as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width) + 4, height: max(16, ceil(size.height) + 4))
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = Theme.font(size: 11.5)
        let text = NSAttributedString(string: linkTitle, attributes: [
            .font: font,
            .foregroundColor: Theme.accent
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: 2, y: bounds.midY - size.height / 2))
        guard window?.firstResponder === self else { return }
        Theme.accent.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        ring.lineWidth = 2
        ring.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class BlockListSearchField: NSView {
    let field = NSTextField(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let glyph = GlyphView()
        glyph.glyph = .search
        glyph.pointSize = 13
        glyph.tint = Theme.mute
        glyph.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.font(size: 12.5)
        field.textColor = Theme.text
        field.placeholderString = "Search allowed sites"
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Search allowed sites")
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(field)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 13),
            glyph.heightAnchor.constraint(equalToConstant: 13),
            field.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === self ? field : hit
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 200, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        FieldFrame.draw(in: bounds, radius: 7)
        guard field.currentEditor() != nil else { return }
        Theme.accent.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        ring.lineWidth = 2
        ring.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        field.textColor = Theme.text
        needsDisplay = true
    }
}

@MainActor
private final class BlockListAllowRow: NSView {
    let removeButton = RevealCloseButton()
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        removeButton.onFocus = { [weak self] in
            self?.refreshRemove()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshRemove()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshRemove()
    }

    func refreshRemove() {
        let focused = window?.firstResponder === removeButton
        removeButton.alphaValue = (hovered || focused) ? 1 : 0
    }
}

@MainActor
private final class RevealCloseButton: NSButton {
    var onFocus: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var refusesFirstResponder: Bool {
        get { false }
        set {}
    }

    override var canBecomeKeyView: Bool {
        isEnabled && isHidden == false
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        onFocus?()
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        onFocus?()
        needsDisplay = true
        return ok
    }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 12
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        IconDrawing.stroke(.close, in: rect, color: Theme.mute)
        guard window?.firstResponder === self else { return }
        Theme.accent.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        ring.lineWidth = 2
        ring.stroke()
    }
}

private enum BlockListDates {
    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy, h:mm a"
        return formatter.string(from: date)
    }

    static func monthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
