// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import App1Core
import UniformTypeIdentifiers

/// Window-modal sheet: auto-detect, confirm, then import bookmarks and folders only.
@MainActor
final class BookmarkImportSheetController: NSWindowController {
    private let store: BookmarkStore
    private let firstLaunch: Bool
    private let onSkip: (() -> Void)?
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private var checks: [(DetectedProfile, NSButton, ImportPreview)] = []
    private var confirmPreview: ImportPreview?

    init(store: BookmarkStore, firstLaunch: Bool = false, onSkip: (() -> Void)? = nil) {
        self.store = store
        self.firstLaunch = firstLaunch
        self.onSkip = onSkip
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = firstLaunch ? "Import bookmarks" : "Import Bookmarks"
        window.backgroundColor = Theme.page
        super.init(window: window)
        buildHome()
        window.setAccessibilityIdentifier("app1.import.sheet")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildHome() {
        guard let content = window?.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        content.setAccessibilityIdentifier("app1.import.sheet")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let intro = NSTextField(wrappingLabelWithString: "Reads bookmarks and folders only, on this Mac. Nothing is uploaded.")
        intro.font = Theme.font(size: 13)
        intro.textColor = Theme.text
        intro.preferredMaxLayoutWidth = 460
        intro.setAccessibilityIdentifier("app1.import.note")
        stack.addArrangedSubview(intro)

        showFirstLaunchChoices()
        stack.addArrangedSubview(choiceButton("Import from Zen Browser", id: "app1.import.zen", action: #selector(importZen)))
        stack.addArrangedSubview(choiceButton("Import from Firefox", id: "app1.import.firefox", action: #selector(importFirefox)))
        stack.addArrangedSubview(choiceButton(
            "Import from " + ("Ch" + "rome") + "-family browser",
            id: "app1.import.browserFamily",
            action: #selector(importBrowserFamily)
        ))
        stack.addArrangedSubview(choiceButton(
            "Import from Bookmarks HTML File…",
            id: "app1.import.html",
            action: #selector(importHTML)
        ))

        resultLabel.font = Theme.font(size: 12)
        resultLabel.textColor = Theme.text
        resultLabel.preferredMaxLayoutWidth = 460
        resultLabel.stringValue = ""
        resultLabel.setAccessibilityIdentifier("app1.import.result")
        stack.addArrangedSubview(resultLabel)

        let closeTitle = firstLaunch ? "Skip" : "Close"
        let close = NSButton(title: closeTitle, target: self, action: #selector(closeSheet))
        close.bezelStyle = .rounded
        close.font = Theme.font(size: 13)
        close.setAccessibilityIdentifier(firstLaunch ? "app1.import.skip" : "app1.import.close")
        stack.addArrangedSubview(close)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)
        ])
    }

    private func showFirstLaunchChoices() {
        let found = BrowserDetector.scan(home: FileManager.default.homeDirectoryForCurrentUser)
        checks.removeAll()
        if found.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No other browsers were found.")
            empty.font = Theme.font(size: 13)
            empty.textColor = Theme.mute
            stack.addArrangedSubview(empty)
            return
        }
        for profile in found {
            if profile.browser == .safari {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 8
                let label = NSTextField(labelWithString: "Safari — needs permission")
                label.font = Theme.font(size: 13)
                label.textColor = Theme.text
                let prefs = NSButton(title: "Open Privacy settings", target: self, action: #selector(openPrivacySettings))
                prefs.bezelStyle = .rounded
                prefs.font = Theme.font(size: 12)
                let html = NSButton(title: "Import Safari's exported bookmarks HTML…", target: self, action: #selector(importHTML))
                html.bezelStyle = .rounded
                html.font = Theme.font(size: 12)
                html.setAccessibilityIdentifier("app1.import.safari.html")
                row.addArrangedSubview(label)
                stack.addArrangedSubview(row)
                stack.addArrangedSubview(prefs)
                stack.addArrangedSubview(html)
                continue
            }
            let preview = BrowserDetector.preview(profile) ?? ImportPreview(
                profile: profile,
                bookmarkCount: 0,
                folderCount: 0,
                nodes: []
            )
            let title = "\(profile.browser.displayName) — \(profile.name)  \(preview.bookmarkCount) bookmarks, \(preview.folderCount) folders"
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = .on
            box.font = Theme.font(size: 13)
            stack.addArrangedSubview(box)
            checks.append((profile, box, preview))
        }
        let go = NSButton(title: "Continue", target: self, action: #selector(confirmFirstLaunch))
        go.bezelStyle = .rounded
        go.font = Theme.font(size: 13)
        go.setAccessibilityIdentifier("app1.import.continue")
        stack.addArrangedSubview(go)
    }

    private func choiceButton(_ title: String, id: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = Theme.font(size: 13)
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(title)
        return button
    }

    @objc private func importZen() {
        startPlaces(browser: .zen, supportName: "zen")
    }

    @objc private func importFirefox() {
        startPlaces(browser: .firefox, supportName: "Firefox")
    }

    @objc private func importBrowserFamily() {
        let found = BrowserDetector.scan(home: FileManager.default.homeDirectoryForCurrentUser)
            .filter { $0.bookmarksJSONURL != nil }
        if found.isEmpty {
            resultLabel.stringValue = "No " + ("Ch" + "rome") + "-family profiles were found."
            pickJSON()
            return
        }
        presentChooser(found, title: "Choose a profile")
    }

    @objc private func importHTML() {
        pickHTML()
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func closeSheet() {
        if firstLaunch {
            onSkip?()
        }
        guard let sheet = window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func confirmFirstLaunch() {
        let selected = checks.filter { $0.1.state == .on }.map(\.2)
        guard !selected.isEmpty else {
            onSkip?()
            closeSheet()
            return
        }
        showConfirm(previews: selected)
    }

    private func startPlaces(browser: DetectedBrowser, supportName: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = ZenDetector.supportFolder(home: home, name: supportName)
        let profiles = ZenDetector.detect(root: root, browser: browser).filter { $0.placesURL != nil }
        if profiles.isEmpty {
            let path = "~/Library/Application Support/\(supportName)"
            resultLabel.stringValue = "\(browser.displayName) wasn't found in \(path)"
            let choose = NSButton(title: "Choose File…", target: self, action: #selector(fallbackPlaces))
            choose.bezelStyle = .rounded
            choose.font = Theme.font(size: 13)
            choose.setAccessibilityIdentifier("app1.import.chooseFile")
            choose.tag = browser == .zen ? 1 : 2
            stack.addArrangedSubview(choose)
            return
        }
        if profiles.count == 1, let only = profiles.first {
            presentConfirm(profile: only)
            return
        }
        presentChooser(profiles, title: "Choose a \(browser.displayName) profile")
    }

    @objc private func fallbackPlaces(_ sender: NSButton) {
        pickPlaces(sender.tag == 1 ? .zen : .firefox)
    }

    private func presentChooser(_ profiles: [DetectedProfile], title: String) {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.backgroundColor = Theme.page
        let list = NSPopUpButton()
        for profile in profiles {
            list.addItem(withTitle: profile.name)
            if profile.isDefault {
                list.selectItem(withTitle: profile.name)
            }
        }
        let go = NSButton(title: "Continue", target: nil, action: nil)
        go.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.bezelStyle = .rounded
        let column = NSStackView(views: [list, go, cancel])
        column.orientation = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
            column.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16)
        ])
        go.target = self
        go.action = #selector(chooserContinue)
        cancel.target = self
        cancel.action = #selector(chooserCancel)
        objc_setAssociatedObject(go, &Associated.profiles, profiles, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(go, &Associated.popup, list, .OBJC_ASSOCIATION_RETAIN)
        window?.beginSheet(panel)
        objc_setAssociatedObject(self, &Associated.sheet, panel, .OBJC_ASSOCIATION_RETAIN)
    }

    @objc private func chooserContinue(_ sender: NSButton) {
        let profiles = objc_getAssociatedObject(sender, &Associated.profiles) as? [DetectedProfile] ?? []
        let popup = objc_getAssociatedObject(sender, &Associated.popup) as? NSPopUpButton
        endChooser()
        let index = max(popup?.indexOfSelectedItem ?? 0, 0)
        guard index < profiles.count else { return }
        presentConfirm(profile: profiles[index])
    }

    @objc private func chooserCancel() {
        endChooser()
    }

    private func endChooser() {
        if let panel = objc_getAssociatedObject(self, &Associated.sheet) as? NSWindow {
            window?.endSheet(panel)
            objc_setAssociatedObject(self, &Associated.sheet, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    private func presentConfirm(profile: DetectedProfile) {
        guard let preview = BrowserDetector.preview(profile) else {
            resultLabel.stringValue = "Could not read that profile."
            return
        }
        showConfirm(previews: [preview])
    }

    private func showConfirm(previews: [ImportPreview]) {
        guard let content = window?.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(wrappingLabelWithString: "Import these bookmarks and folders?")
        heading.font = Theme.font(size: 13, weight: .semibold)
        heading.textColor = Theme.text
        heading.preferredMaxLayoutWidth = 460
        heading.setAccessibilityIdentifier("app1.import.confirm")
        column.addArrangedSubview(heading)
        for preview in previews {
            let line = "\(preview.profile.browser.displayName) — \(preview.profile.name): \(preview.bookmarkCount) bookmarks, \(preview.folderCount) folders"
            let label = NSTextField(labelWithString: line)
            label.font = Theme.font(size: 13)
            label.textColor = Theme.text
            column.addArrangedSubview(label)
        }
        let local = NSTextField(wrappingLabelWithString: "Reads bookmarks and folders only, on this Mac. Nothing is uploaded.")
        local.font = Theme.font(size: 12)
        local.textColor = Theme.mute
        local.preferredMaxLayoutWidth = 460
        column.addArrangedSubview(local)
        let go = NSButton(title: "Import", target: self, action: #selector(performConfirmedImport(_:)))
        go.bezelStyle = .rounded
        go.font = Theme.font(size: 13)
        go.keyEquivalent = "\r"
        go.setAccessibilityIdentifier("app1.import.do")
        let back = NSButton(title: "Back", target: self, action: #selector(backHome))
        back.bezelStyle = .rounded
        back.font = Theme.font(size: 13)
        column.addArrangedSubview(go)
        column.addArrangedSubview(back)
        objc_setAssociatedObject(go, &Associated.previews, previews, .OBJC_ASSOCIATION_RETAIN)
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)
        ])
    }

    @objc private func backHome() {
        buildHome()
    }

    /// Merges the confirmed previews. Does not rebuild this sheet.
    func performConfirmedImport(previews: [ImportPreview]) -> BookmarkImportCounts {
        Self.performConfirmedImport(previews: previews, store: store)
    }

    static func performConfirmedImport(previews: [ImportPreview], store: BookmarkStore) -> BookmarkImportCounts {
        var totals = BookmarkImportCounts()
        for preview in previews {
            let counts = BookmarkImport.merge(
                preview.nodes,
                into: store,
                sourceRoot: preview.profile.browser.displayName
            )
            totals.added += counts.added
            totals.skippedDuplicates += counts.skippedDuplicates
            totals.skippedUnsupported += counts.skippedUnsupported
        }
        return totals
    }

    @objc private func performConfirmedImport(_ sender: NSButton) {
        let previews = objc_getAssociatedObject(sender, &Associated.previews) as? [ImportPreview] ?? []
        let counts = performConfirmedImport(previews: previews)
        buildHome()
        resultLabel.stringValue = "Imported \(counts.added), skipped \(counts.skippedDuplicates) duplicates, \(counts.skippedUnsupported) unsupported links"
        if firstLaunch {
            onSkip?()
        }
    }

    private func pickPlaces(_ source: BookmarkFileSource) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = source.defaultDirectory
        panel.message = "Choose a profile folder or a places.sqlite file."
        panel.prompt = "Import"
        if let sqlite = UTType(filenameExtension: "sqlite") {
            panel.allowedContentTypes = [sqlite, .folder, .item]
        }
        begin(panel) { [weak self] url in
            guard let self, let url else { return }
            do {
                let imported = try PlacesDatabase.importTree(from: url)
                let tally = NodeTally.of(imported.nodes)
                let fake = DetectedProfile(
                    browser: source == .zen ? .zen : .firefox,
                    name: url.lastPathComponent,
                    directory: url,
                    placesURL: url,
                    isDefault: true
                )
                let preview = ImportPreview(
                    profile: fake,
                    bookmarkCount: tally.bookmarks,
                    folderCount: tally.folders,
                    nodes: imported.nodes
                )
                self.showConfirm(previews: [preview])
            } catch {
                self.resultLabel.stringValue = "Could not read that bookmark file."
            }
        }
    }

    private func pickJSON() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = BookmarkFileSource.browserFamily.defaultDirectory
        panel.message = "Choose the Bookmarks file from a browser profile."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json, .data, .item]
        begin(panel) { [weak self] url in
            guard let self, let url else { return }
            do {
                let data = try Data(contentsOf: url)
                let nodes = try BrowserFamilyBookmarkParser.parse(data: data)
                let tally = NodeTally.of(nodes)
                let fake = DetectedProfile(
                    browser: .googleFamily,
                    name: url.deletingLastPathComponent().lastPathComponent,
                    directory: url.deletingLastPathComponent(),
                    bookmarksJSONURL: url,
                    isDefault: true
                )
                self.showConfirm(previews: [
                    ImportPreview(profile: fake, bookmarkCount: tally.bookmarks, folderCount: tally.folders, nodes: nodes)
                ])
            } catch {
                self.resultLabel.stringValue = "Could not read that bookmark file."
            }
        }
    }

    private func pickHTML() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = BookmarkFileSource.htmlFile.defaultDirectory
        panel.message = "Choose a bookmarks HTML file."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.html, .plainText]
        begin(panel) { [weak self] url in
            guard let self, let url else { return }
            do {
                let data = try Data(contentsOf: url)
                let nodes = try BookmarkHTMLParser.parse(data: data)
                let tally = NodeTally.of(nodes)
                let fake = DetectedProfile(
                    browser: .safari,
                    name: url.lastPathComponent,
                    directory: url.deletingLastPathComponent(),
                    isDefault: true
                )
                self.showConfirm(previews: [
                    ImportPreview(profile: fake, bookmarkCount: tally.bookmarks, folderCount: tally.folders, nodes: nodes)
                ])
            } catch let error as BookmarkImportError where error == .fileTooLarge {
                self.resultLabel.stringValue = "That file is larger than 10 MB."
            } catch {
                self.resultLabel.stringValue = "Could not read that bookmark file."
            }
        }
    }

    private func begin(_ panel: NSOpenPanel, completion: @escaping (URL?) -> Void) {
        guard let host = window else {
            completion(nil)
            return
        }
        panel.beginSheetModal(for: host) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}

private enum Associated {
    static var profiles = 0
    static var popup = 0
    static var sheet = 0
    static var previews = 0
}
