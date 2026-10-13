// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import App1Core
import WebKit

/// Setup rows and settings switches toggle on mouse-down, before mouse-up.
/// `accessibilityPerformPress` does the same for the accessibility press path.
@MainActor
class SettingsToggle: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        state = state == .on ? .off : .on
        sendAction(action, to: target)
        return true
    }
}

/// Setup appearance choices and settings theme radios select on mouse-down.
@MainActor
class SettingsRadio: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        state = .on
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        state = .on
        sendAction(action, to: target)
        return true
    }
}

/// S1 panes. Command-1 through Command-4 stay Appearance, General, Updates, and Terminal.
/// Privacy and Downloads are appended after those four.
fileprivate enum SettingsPane: Int {
    case appearance = 1
    case general = 2
    case updates = 3
    case terminal = 4
    case privacy = 5
    case downloads = 6

    static let installed: [SettingsPane] = [.appearance, .general, .updates, .terminal, .privacy, .downloads]

    var navID: String {
        switch self {
        case .appearance: return "appearance"
        case .general: return "general"
        case .updates: return "updates"
        case .terminal: return "terminal"
        case .privacy: return "privacy"
        case .downloads: return "downloads"
        }
    }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .general: return "General"
        case .updates: return "Updates"
        case .terminal: return "Terminal"
        case .privacy: return "Privacy"
        case .downloads: return "Downloads"
        }
    }

    var glyph: IconGlyph {
        switch self {
        case .appearance: return .sun
        case .general: return .dial
        case .updates: return .download
        case .terminal: return .terminal
        case .privacy: return .lock
        case .downloads: return .download
        }
    }
}

/// S1 content metrics. Every pane uses the same top inset and title spacing.
private enum SettingsLayout {
    static let paddingH: CGFloat = 28
    static let paddingV: CGFloat = 24
    /// Title bar occupies the strip. The 24pt content padding sits below it.
    static let topInset: CGFloat = MonoMetrics.stripHeight + paddingV
    /// S2 documents a 560pt card column; S1 centres that same max width in the detail pane.
    static let contentMaxWidth: CGFloat = 560
    static let titleToSubtitle: CGFloat = 2
    static let afterSubtitle: CGFloat = 18
    static let groupTop: CGFloat = 18
    static let groupBottom: CGFloat = 6
    static let engineTileHeight: CGFloat = 58
    static let engineTileGap: CGFloat = 6
    static let engineBadge: CGFloat = 22
    static let engineBadgeGap: CGFloat = 5
    static let engineTilePad: CGFloat = 8
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// Window-menu Command-1…N while Settings is key. Matches `SettingsPane.installed`.
    static var installedPaneCount: Int { SettingsPane.installed.count }
    private let settings: SettingsStore
    private let bookmarks: BookmarkStore
    private let mediaPermissions: MediaPermissionStore
    private let sitePermissions: SitePermissionStore
    private let updater: AppUpdater?
    private let terminalBookmarks: TerminalBookmarkStore
    private let systemChoice = SettingsThemeChoice(title: "Match System", preference: .system)
    private let lightChoice = SettingsThemeChoice(title: "Light", preference: .light)
    private let darkChoice = SettingsThemeChoice(title: "Dark", preference: .dark)
    private let hideWebToggle = SettingsSwitch(label: "Hide web tabs")
    private let hideTerminalToggle = SettingsSwitch(label: "Hide terminal tabs")
    private let netHealthToggle = SettingsSwitch(label: "Show network health")
    private let hardwareAccelerationToggle = SettingsSwitch(label: "Hardware acceleration")
    private let engineTiles: [SettingsEngineTile] = SearchEngine.builtIns.map {
        SettingsEngineTile(engineID: $0.id, name: $0.name)
    } + [SettingsEngineTile(engineID: SearchEngine.customID, name: "Custom")]
    private let templateFrame = SettingsFieldFrame()
    private let noteLabel = SettingsLabel(role: .note, text: "")
    private let defaultBrowserStatus = SettingsLabel(role: .detail, text: "")
    private let feedFrame = SettingsFieldFrame()
    private let keyFrame = SettingsFieldFrame()
    private let sourceStatus = SettingsLabel(role: .detail, text: "")
    private let saveSourceButton = DepthButton(title: "Use This Source", kind: .secondary)
    private let resetSourceButton = DepthButton(title: "Reset to Default", kind: .secondary)
    private let copyKeyButton = DepthButton(title: "Copy", kind: .secondary)
    private let updateButton = DepthButton(title: "Check for updates", kind: .primary)
    private let makeDefaultButton = DepthButton(title: "Make default", kind: .primary)
    private let removeAllButton = DepthButton(title: "Remove All", kind: .secondary)
    private let permissionsStack = NSStackView()
    private let importStack = NSStackView()
    private let lightBand = NSView()
    private let contentHost = NSView()
    private var paneViews: [SettingsPane: NSView] = [:]
    private var navButtons: [SettingsNavButton] = []
    private var currentPane: SettingsPane = .appearance
    private var importScanned = false
    private var importProfiles: [DetectedProfile] = []
    private var clearing = false
    private var applying = false
    private var positioningLights = false
    private var permissionsObserver: NSObjectProtocol?
    private var sitePermissionsObserver: NSObjectProtocol?
    private var contrastObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private let terminalListStack = NSStackView()
    private let terminalNewTabToggle = SettingsSwitch(label: "Open in new tab")
    private let terminalShellPopup = SettingsPopUpButton()
    private let terminalFontPopup = SettingsPopUpButton()
    private let terminalAddButton = DepthButton(title: "Add", kind: .primary)
    private let cookiePolicyPopup = SettingsPopUpButton()
    private let startupPagePopup = SettingsPopUpButton()
    private let startupURLFrame = SettingsFieldFrame()
    private let fontSizePopup = SettingsPopUpButton()
    private let zoomPopup = SettingsPopUpButton()
    private let askDownloadsToggle = SettingsSwitch(label: "Ask where to save each time")
    private let openAfterDownloadToggle = SettingsSwitch(label: "Open after download")
    private let downloadsPathLabel = SettingsLabel(role: .detail, text: "")
    private let chooseDownloadsButton = DepthButton(title: "Choose…", kind: .secondary)
    private let manageSiteDataButton = DepthButton(title: "Manage site data…", kind: .secondary)
    private var siteDataSheet: SiteDataSheetController?
    private var bookmarkEditor: TerminalBookmarkEditor?
    private var terminalObserver: NSObjectProtocol?

    private var templateField: NSTextField { templateFrame.field }
    private var feedURLField: NSTextField { feedFrame.field }
    private var keyField: NSTextField { keyFrame.field }
    private var startupURLField: NSTextField { startupURLFrame.field }

    init(
        settings: SettingsStore,
        bookmarks: BookmarkStore,
        mediaPermissions: MediaPermissionStore,
        sitePermissions: SitePermissionStore,
        updater: AppUpdater? = nil,
        terminalBookmarks: TerminalBookmarkStore
    ) {
        self.settings = settings
        self.bookmarks = bookmarks
        self.mediaPermissions = mediaPermissions
        self.sitePermissions = sitePermissions
        self.updater = updater
        self.terminalBookmarks = terminalBookmarks
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.page
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        window.setContentSize(NSSize(width: 860, height: 620))
        build()
        reloadFromStore()
        reloadPermissions()
        reloadUpdateSource()
        permissionsObserver = NotificationCenter.default.addObserver(
            forName: .app1MediaPermissionsDidChange,
            object: mediaPermissions,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadPermissions()
            }
        }
        sitePermissionsObserver = NotificationCenter.default.addObserver(
            forName: .app1SitePermissionsDidChange,
            object: sitePermissions,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadPermissions()
            }
        }
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshContrast()
            }
        }
        window.setAccessibilityIdentifier("app1.settings")
        installKeyMonitor()
        terminalObserver = NotificationCenter.default.addObserver(
            forName: .app1TerminalBookmarksDidChange,
            object: terminalBookmarks,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadTerminalBookmarks()
            }
        }
        show(.appearance)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let permissionsObserver {
            NotificationCenter.default.removeObserver(permissionsObserver)
        }
        if let sitePermissionsObserver {
            NotificationCenter.default.removeObserver(sitePermissionsObserver)
        }
        if let contrastObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(contrastObserver)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let terminalObserver {
            NotificationCenter.default.removeObserver(terminalObserver)
        }
    }

    /// 1-based, matching the Window menu tags. Out-of-range numbers do nothing.
    func selectPane(number: Int) {
        guard let pane = SettingsPane(rawValue: number), SettingsPane.installed.contains(pane) else { return }
        show(pane)
        if let button = navButtons.first(where: { $0.pane == pane }) {
            window?.makeFirstResponder(button)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        installKeyMonitor()
        centerLights()
        DispatchQueue.main.async { [weak self] in
            self?.centerLights()
        }
    }

    func windowDidResize(_ notification: Notification) {
        centerLights()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.object as? NSTextField)?.superview?.needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        (obj.object as? NSTextField)?.superview?.needsDisplay = true
        guard let field = obj.object as? NSTextField else { return }
        if field === templateField {
            saveEngine()
        } else if field === startupURLField {
            saveStartupURL()
        }
    }

    private func build() {
        guard let window else { return }
        let content = PageBackdrop()
        window.contentView = content
        content.wantsLayer = true
        content.layer?.cornerRadius = MonoMetrics.windowRadius
        content.layer?.masksToBounds = true

        let sidebar = SettingsSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        lightBand.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        content.addSubview(contentHost)
        sidebar.addSubview(lightBand)

        let header = makeHeader()
        sidebar.addSubview(header)
        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 2
        nav.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(nav)
        for pane in SettingsPane.installed {
            addNav(pane, stack: nav)
        }

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: MonoMetrics.settingsSidebarWidth),
            lightBand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            lightBand.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            lightBand.topAnchor.constraint(equalTo: sidebar.topAnchor),
            lightBand.heightAnchor.constraint(equalToConstant: MonoMetrics.stripHeight),
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: lightBand.bottomAnchor, constant: 4),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            nav.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            contentHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: content.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        configureChoices()
        configureToggles()
        configureEngines()
        configureSourceControls()
        configureTerminalControls()
        configureBrowserControls()
        paneViews[.appearance] = makeScroll(column: appearanceColumn())
        paneViews[.general] = makeScroll(column: generalColumn())
        paneViews[.updates] = makeScroll(column: updatesColumn())
        paneViews[.terminal] = makeScroll(column: terminalColumn())
        paneViews[.privacy] = makeScroll(column: privacyColumn())
        paneViews[.downloads] = makeScroll(column: downloadsColumn())
    }

    private func makeHeader() -> NSView {
        let icon = SettingsAppIcon()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = SettingsLabel(role: .headerTitle, text: AppInfo.productName)
        let subtitle = SettingsLabel(role: .headerSubtitle, text: "Settings")
        let words = NSStackView(views: [name, subtitle])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        let header = NSStackView(views: [icon, words])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return header
    }

    private func addNav(_ pane: SettingsPane, stack: NSStackView) {
        let button = SettingsNavButton(pane: pane)
        button.target = self
        button.action = #selector(navTapped(_:))
        button.onMove = { [weak self] delta in
            self?.movePane(by: delta)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        navButtons.append(button)
    }

    private func configureChoices() {
        let choices = [lightChoice, darkChoice, systemChoice]
        let ids = [
            "app1.settings.lightAppearance",
            "app1.settings.appearance.dark",
            "app1.settings.appearance.system"
        ]
        for (choice, id) in zip(choices, ids) {
            choice.target = self
            choice.action = #selector(appearancePicked(_:))
            choice.setAccessibilityIdentifier(id)
            choice.translatesAutoresizingMaskIntoConstraints = false
            choice.heightAnchor.constraint(equalToConstant: 102).isActive = true
        }
    }

    private func configureToggles() {
        hideWebToggle.target = self
        hideWebToggle.action = #selector(hideWebChanged)
        hideWebToggle.setAccessibilityIdentifier("app1.settings.hideWebTabs")
        hideTerminalToggle.target = self
        hideTerminalToggle.action = #selector(hideTerminalChanged)
        hideTerminalToggle.setAccessibilityIdentifier("app1.settings.hideTerminalTabs")
        netHealthToggle.target = self
        netHealthToggle.action = #selector(netHealthChanged)
        netHealthToggle.setAccessibilityIdentifier("app1.settings.netHealth")
        hardwareAccelerationToggle.target = self
        hardwareAccelerationToggle.action = #selector(hardwareAccelerationChanged)
        hardwareAccelerationToggle.setAccessibilityIdentifier("app1.settings.hardwareAcceleration")
    }

    private func configureEngines() {
        for tile in engineTiles {
            tile.target = self
            tile.action = #selector(enginePicked(_:))
            tile.translatesAutoresizingMaskIntoConstraints = false
            tile.heightAnchor.constraint(equalToConstant: SettingsLayout.engineTileHeight).isActive = true
        }
        templateField.placeholderString = "https://example.com/search?q={query}"
        templateField.target = self
        templateField.action = #selector(templateEdited)
        templateField.delegate = self
        feedURLField.delegate = self
        keyField.delegate = self
    }

    private func configureSourceControls() {
        styleSettingsButton(saveSourceButton)
        styleSettingsButton(resetSourceButton)
        styleSettingsButton(copyKeyButton)
        styleSettingsButton(updateButton)
        styleSettingsButton(makeDefaultButton)
        styleSettingsButton(removeAllButton)
        saveSourceButton.target = self
        saveSourceButton.action = #selector(saveUpdateSource)
        saveSourceButton.setAccessibilityIdentifier("app1.settings.updateSourceSave")
        resetSourceButton.target = self
        resetSourceButton.action = #selector(resetUpdateSource)
        resetSourceButton.setAccessibilityIdentifier("app1.settings.updateSourceReset")
        copyKeyButton.target = self
        copyKeyButton.action = #selector(copyUpdateKey)
        copyKeyButton.setAccessibilityLabel("Copy public key")
        updateButton.target = self
        updateButton.action = #selector(checkUpdates)
        updateButton.setAccessibilityIdentifier("app1.settings.update")
        makeDefaultButton.target = self
        makeDefaultButton.action = #selector(makeDefaultBrowser)
        makeDefaultButton.setAccessibilityIdentifier("app1.settings.makeDefault")
        makeDefaultButton.setAccessibilityLabel("Make \(AppInfo.displayName) the default browser")
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAllPermissions)
        removeAllButton.setAccessibilityIdentifier("app1.settings.permissions.removeAll")
        feedURLField.placeholderString = "https://example.com/wyvern/latest.json"
        feedURLField.setAccessibilityIdentifier("app1.settings.updateSource")
        keyField.placeholderString = "RWQ…"
        keyField.setAccessibilityIdentifier("app1.settings.updateKey")
        sourceStatus.setAccessibilityIdentifier("app1.settings.updateSourceStatus")
        defaultBrowserStatus.setAccessibilityIdentifier("app1.settings.makeDefaultStatus")
        permissionsStack.orientation = .vertical
        permissionsStack.alignment = .leading
        permissionsStack.spacing = 0
        permissionsStack.setAccessibilityIdentifier("app1.settings.permissions")
        importStack.orientation = .vertical
        importStack.alignment = .leading
        importStack.spacing = 0
    }

    private func appearanceColumn() -> NSStackView {
        let column = makeColumn()
        let subtitle = addSection(
            "Appearance",
            id: "app1.settings.section.appearance",
            subtitle: "Theme, network health, and tabs.",
            to: column
        )
        addGroup("Theme", to: column, after: subtitle)
        let themes = NSStackView(views: [lightChoice, darkChoice, systemChoice])
        themes.orientation = .horizontal
        themes.alignment = .centerY
        themes.distribution = .fillEqually
        themes.spacing = 8
        themes.translatesAutoresizingMaskIntoConstraints = false
        themes.heightAnchor.constraint(equalToConstant: 102).isActive = true
        let themeCard = makeCard(padded: true)
        themeCard.stack.addArrangedSubview(themes)
        themes.widthAnchor.constraint(equalTo: themeCard.stack.widthAnchor).isActive = true
        addCard(themeCard.host, to: column)
        let themeAnchor = themeCard.host
        addGroup("Network health", id: "app1.settings.section.network", to: column, after: themeAnchor)
        let network = makeCard(padded: false)
        span(makeRow(
            title: "Show network health",
            detail: "Measures only the current tab's site.",
            control: netHealthToggle
        ), in: network.stack)
        span(SettingsHairline(), in: network.stack)
        let preview = SettingsNetPreview()
        preview.setAccessibilityElement(false)
        let previewRow = makeRow(title: "Preview", detail: nil, control: preview)
        previewRow.setAccessibilityElement(false)
        span(previewRow, in: network.stack)
        addCard(network.host, to: column)
        let networkNote = addNote(
            "Probes only the host of the visible tab, about once a second while this window is visible, plus 30 seconds after it hides. Samples stay in memory for 60 seconds.",
            to: column
        )
        addGroup("Tabs", to: column, after: networkNote)
        let tabs = makeCard(padded: false)
        span(makeRow(
            title: "Hide web tabs",
            detail: "Hides the web tab strip.",
            control: hideWebToggle
        ), in: tabs.stack)
        span(SettingsHairline(), in: tabs.stack)
        span(makeRow(
            title: "Hide terminal tabs",
            detail: "Hides the terminal tab strip.",
            control: hideTerminalToggle
        ), in: tabs.stack)
        addCard(tabs.host, to: column)
        let tabsNote = addNote(
            "One of web or terminal must stay visible.",
            to: column
        )
        addGroup("Web pages", to: column, after: tabsNote)
        let pages = makeCard(padded: false)
        span(makeRow(
            title: "Default font size",
            detail: "Points, from 12 to 24.",
            control: fontSizePopup
        ), in: pages.stack)
        span(SettingsHairline(), in: pages.stack)
        span(makeRow(
            title: "Default zoom",
            detail: "Page zoom, from 50% to 200%.",
            control: zoomPopup
        ), in: pages.stack)
        addCard(pages.host, to: column)
        _ = addNote(
            "Applies to open web tabs now.",
            to: column
        )
        return column
    }

    private func generalColumn() -> NSStackView {
        let column = makeColumn()
        let subtitle = addSection(
            "General",
            id: "app1.settings.section.general",
            subtitle: "Search, bookmarks, and the default browser.",
            to: column
        )
        addGroup("Search", to: column, after: subtitle)
        let engines = NSStackView(views: engineTiles)
        engines.orientation = .horizontal
        engines.alignment = .centerY
        engines.distribution = .fillEqually
        engines.spacing = SettingsLayout.engineTileGap
        engines.translatesAutoresizingMaskIntoConstraints = false
        let search = makeCard(padded: true)
        search.stack.spacing = 10
        search.stack.addArrangedSubview(engines)
        engines.widthAnchor.constraint(equalTo: search.stack.widthAnchor).isActive = true
        engines.heightAnchor.constraint(equalToConstant: SettingsLayout.engineTileHeight).isActive = true
        search.stack.addArrangedSubview(templateFrame)
        templateFrame.widthAnchor.constraint(equalTo: search.stack.widthAnchor).isActive = true
        templateFrame.heightAnchor.constraint(equalToConstant: 28).isActive = true
        search.stack.addArrangedSubview(noteLabel)
        noteLabel.widthAnchor.constraint(equalTo: search.stack.widthAnchor).isActive = true
        addCard(search.host, to: column)
        addGroup("Bookmarks", id: "app1.settings.section.bookmarks", to: column, after: search.host)
        let imports = makeCard(padded: false)
        imports.stack.addArrangedSubview(importStack)
        importStack.widthAnchor.constraint(equalTo: imports.stack.widthAnchor).isActive = true
        addCard(imports.host, to: column)
        let importNote = addNote(
            "Reads bookmarks and folders only, on this Mac. Nothing is uploaded.",
            to: column
        )
        addGroup("Data", to: column, after: importNote)
        let clearButton = DepthButton(title: "Clear Browsing Data", kind: .secondary)
        styleSettingsButton(clearButton)
        clearButton.target = self
        clearButton.action = #selector(clearBrowsingData)
        let deleteButton = DepthButton(title: "Delete All Bookmarks", kind: .secondary)
        styleSettingsButton(deleteButton)
        deleteButton.target = self
        deleteButton.action = #selector(deleteAllBookmarks)
        let data = makeCard(padded: false)
        span(makeRow(
            title: "Clear browsing data",
            detail: "Site data and cached icons. Bookmarks are kept.",
            control: clearButton
        ), in: data.stack)
        span(SettingsHairline(), in: data.stack)
        span(makeRow(
            title: "Delete all bookmarks",
            detail: "Removes every bookmark and folder.",
            control: deleteButton
        ), in: data.stack)
        addCard(data.host, to: column)
        addGroup("Site permissions", to: column, after: data.host)
        let permissions = makeCard(padded: false)
        permissions.stack.addArrangedSubview(permissionsStack)
        permissionsStack.widthAnchor.constraint(equalTo: permissions.stack.widthAnchor).isActive = true
        addCard(permissions.host, to: column)
        let permissionNote = addNote(
            "Location and notifications have no prompt. Those choices are saved, and the page is not granted access.",
            to: column
        )
        addGroup("Default browser", to: column, after: permissionNote)
        let browser = makeCard(padded: false)
        span(makeRow(
            title: "Default browser",
            detailLabel: defaultBrowserStatus,
            control: makeDefaultButton
        ), in: browser.stack)
        addCard(browser.host, to: column)
        addGroup("Performance", to: column, after: browser.host)
        let performance = makeCard(padded: false)
        span(makeRow(
            title: "Hardware acceleration",
            detail: "GPU canvas and WebGL in web pages.",
            control: hardwareAccelerationToggle
        ), in: performance.stack)
        addCard(performance.host, to: column)
        let performanceNote = addNote(
            "Turns off GPU canvas and WebGL. Page compositing always uses the GPU on macOS. Applies to new tabs or after relaunch.",
            to: column
        )
        addGroup("Startup", to: column, after: performanceNote)
        let startup = makeCard(padded: false)
        span(makeRow(
            title: "Startup page",
            detail: "Opened on a normal launch.",
            control: startupPagePopup
        ), in: startup.stack)
        span(SettingsHairline(), in: startup.stack)
        startupURLFrame.widthAnchor.constraint(equalToConstant: 260).isActive = true
        startupURLFrame.heightAnchor.constraint(equalToConstant: 28).isActive = true
        span(makeRow(
            title: "Custom URL",
            detail: "Used when startup is Custom URL.",
            control: startupURLFrame
        ), in: startup.stack)
        addCard(startup.host, to: column)
        _ = addNote(
            "An unclean exit asks before this. An empty custom URL opens a new tab.",
            to: column
        )
        return column
    }

    private func updatesColumn() -> NSStackView {
        let column = makeColumn()
        let subtitle = addSection(
            "Updates",
            id: "app1.settings.section.updates",
            subtitle: "Checks run only when you click.",
            to: column
        )
        addGroup("Source", to: column, after: subtitle)
        let source = makeCard(padded: true)
        source.stack.spacing = 8
        let feedCaption = SettingsLabel(role: .detail, text: "Feed URL")
        let keyCaption = SettingsLabel(
            role: .detail,
            text: "Public key for this source (minisign, starts with RWQ)"
        )
        source.stack.addArrangedSubview(feedCaption)
        source.stack.addArrangedSubview(feedFrame)
        feedFrame.widthAnchor.constraint(equalTo: source.stack.widthAnchor).isActive = true
        feedFrame.heightAnchor.constraint(equalToConstant: 28).isActive = true
        source.stack.addArrangedSubview(keyCaption)
        let keyRow = NSStackView(views: [keyFrame, copyKeyButton])
        keyRow.orientation = .horizontal
        keyRow.alignment = .centerY
        keyRow.spacing = 8
        keyRow.translatesAutoresizingMaskIntoConstraints = false
        keyFrame.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        keyFrame.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyKeyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyKeyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        source.stack.addArrangedSubview(keyRow)
        keyRow.widthAnchor.constraint(equalTo: source.stack.widthAnchor).isActive = true
        keyFrame.heightAnchor.constraint(equalToConstant: 28).isActive = true
        source.stack.addArrangedSubview(sourceStatus)
        sourceStatus.widthAnchor.constraint(equalTo: source.stack.widthAnchor).isActive = true
        let actions = NSStackView(views: [saveSourceButton, resetSourceButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        source.stack.addArrangedSubview(actions)
        addCard(source.host, to: column)
        let security = addNote(
            "Checks run only when you click. An update is installed only if it carries a valid signature from the key below; that check cannot be skipped. Changing the source always needs its key. See docs/UPDATES.md to host your own.",
            to: column
        )
        addGroup("Version", to: column, after: security)
        let commit = AppInfo.gitCommit.isEmpty ? "unknown" : AppInfo.gitCommit
        let version = makeCard(padded: false)
        span(makeRow(
            title: "Version \(AppInfo.marketingVersion) (\(commit))",
            titleID: "app1.settings.version",
            detail: "Nothing is downloaded until you confirm.",
            control: updateButton
        ), in: version.stack)
        addCard(version.host, to: column)
        return column
    }

    private func configureTerminalControls() {
        styleSettingsButton(terminalAddButton)
        terminalAddButton.target = self
        terminalAddButton.action = #selector(addTerminalBookmark)
        terminalAddButton.setAccessibilityIdentifier("app1.settings.terminal.add")
        terminalAddButton.setAccessibilityLabel("Add terminal bookmark")

        terminalNewTabToggle.target = self
        terminalNewTabToggle.action = #selector(terminalDefaultsChanged)
        terminalNewTabToggle.setAccessibilityIdentifier("app1.settings.terminal.openInNewTab")

        let shells = [
            ("Default (login shell)", ""),
            ("/bin/zsh", "/bin/zsh"),
            ("/bin/bash", "/bin/bash"),
            ("/bin/sh", "/bin/sh")
        ]
        terminalShellPopup.removeAllItems()
        for (title, value) in shells {
            terminalShellPopup.addItem(withTitle: title)
            terminalShellPopup.lastItem?.representedObject = value
        }
        terminalShellPopup.target = self
        terminalShellPopup.action = #selector(terminalDefaultsChanged)
        terminalShellPopup.setAccessibilityIdentifier("app1.settings.terminal.shell")

        terminalFontPopup.removeAllItems()
        for size in 11...18 {
            terminalFontPopup.addItem(withTitle: "\(size)")
        }
        terminalFontPopup.target = self
        terminalFontPopup.action = #selector(terminalDefaultsChanged)
        terminalFontPopup.setAccessibilityIdentifier("app1.settings.terminal.fontSize")

        terminalListStack.orientation = .vertical
        terminalListStack.alignment = .leading
        terminalListStack.spacing = 0
        terminalListStack.setAccessibilityIdentifier("app1.settings.terminal.list")
    }

    private func configureBrowserControls() {
        fillPolicyPopup(
            cookiePolicyPopup,
            items: [
                ("Allow all", CookiePolicy.allowAll.rawValue),
                ("Block third-party", CookiePolicy.blockThirdParty.rawValue),
                ("Block all", CookiePolicy.blockAll.rawValue)
            ]
        )
        cookiePolicyPopup.target = self
        cookiePolicyPopup.action = #selector(cookiePolicyChanged)
        cookiePolicyPopup.setAccessibilityIdentifier("app1.settings.cookiePolicy")

        fillPolicyPopup(
            startupPagePopup,
            items: [
                ("New tab", StartupPage.newTab.rawValue),
                ("Restore last session", StartupPage.restoreLastSession.rawValue),
                ("Custom URL", StartupPage.customURL.rawValue)
            ]
        )
        startupPagePopup.target = self
        startupPagePopup.action = #selector(startupPageChanged)
        startupPagePopup.setAccessibilityIdentifier("app1.settings.startupPage")

        startupURLField.placeholderString = "https://example.com"
        startupURLField.target = self
        startupURLField.action = #selector(startupURLEdited)
        startupURLField.delegate = self
        startupURLField.setAccessibilityIdentifier("app1.settings.startupURL")

        fontSizePopup.removeAllItems()
        for size in 12...24 {
            fontSizePopup.addItem(withTitle: "\(size)")
            fontSizePopup.lastItem?.tag = size
        }
        fontSizePopup.target = self
        fontSizePopup.action = #selector(fontSizeChanged)
        fontSizePopup.setAccessibilityIdentifier("app1.settings.fontSize")

        zoomPopup.removeAllItems()
        var percent = 50
        while percent <= 200 {
            zoomPopup.addItem(withTitle: "\(percent)%")
            zoomPopup.lastItem?.tag = percent
            percent += 10
        }
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChanged)
        zoomPopup.setAccessibilityIdentifier("app1.settings.zoom")

        askDownloadsToggle.target = self
        askDownloadsToggle.action = #selector(askDownloadsChanged)
        askDownloadsToggle.setAccessibilityIdentifier("app1.settings.downloads.ask")
        openAfterDownloadToggle.target = self
        openAfterDownloadToggle.action = #selector(openAfterDownloadChanged)
        openAfterDownloadToggle.setAccessibilityIdentifier("app1.settings.downloads.openAfter")

        styleSettingsButton(chooseDownloadsButton)
        chooseDownloadsButton.target = self
        chooseDownloadsButton.action = #selector(chooseDownloadsFolder)
        chooseDownloadsButton.setAccessibilityIdentifier("app1.settings.downloads.choose")
        downloadsPathLabel.setAccessibilityIdentifier("app1.settings.downloads.path")

        styleSettingsButton(manageSiteDataButton)
        manageSiteDataButton.target = self
        manageSiteDataButton.action = #selector(manageSiteData)
        manageSiteDataButton.setAccessibilityIdentifier("app1.settings.siteData")
    }

    private func fillPolicyPopup(_ popup: SettingsPopUpButton, items: [(String, String)]) {
        popup.removeAllItems()
        for (title, raw) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = raw
        }
    }

    private func privacyColumn() -> NSStackView {
        let column = makeColumn()
        let subtitle = addSection(
            "Privacy",
            id: "app1.settings.section.privacy",
            subtitle: "Cookies and stored site data.",
            to: column
        )
        addGroup("Cookies", to: column, after: subtitle)
        let cookies = makeCard(padded: false)
        span(makeRow(
            title: "Cookie policy",
            detail: "Allow all, block third-party, or block all.",
            control: cookiePolicyPopup
        ), in: cookies.stack)
        addCard(cookies.host, to: column)
        let cookieNote = addNote(
            "Applies to new tabs. Third-party blocking keeps first-party cookies.",
            to: column
        )
        addGroup("Site data", to: column, after: cookieNote)
        let data = makeCard(padded: false)
        span(makeRow(
            title: "Site data",
            detail: "Cookies and other data stored by sites.",
            control: manageSiteDataButton
        ), in: data.stack)
        addCard(data.host, to: column)
        _ = addNote(
            "Remove deletes that site's stored data on this Mac.",
            to: column
        )
        return column
    }

    private func downloadsColumn() -> NSStackView {
        let column = makeColumn()
        let subtitle = addSection(
            "Downloads",
            id: "app1.settings.section.downloads",
            subtitle: "Where files are saved.",
            to: column
        )
        addGroup("Location", to: column, after: subtitle)
        let location = makeCard(padded: false)
        span(makeRow(
            title: "Save downloads to",
            detailLabel: downloadsPathLabel,
            control: chooseDownloadsButton
        ), in: location.stack)
        span(SettingsHairline(), in: location.stack)
        span(makeRow(
            title: "Ask where to save each time",
            detail: "Shows a save panel for every download.",
            control: askDownloadsToggle
        ), in: location.stack)
        span(SettingsHairline(), in: location.stack)
        span(makeRow(
            title: "Open after download",
            detail: "Opens the file when the download finishes.",
            control: openAfterDownloadToggle
        ), in: location.stack)
        addCard(location.host, to: column)
        let note: String
        if AppLocations.isDownloadsDirectoryOverridden {
            note = "This launch saves into the folder passed at startup. The folder chosen here is used on the next launch."
        } else {
            note = "New downloads use this folder unless you ask each time."
        }
        _ = addNote(note, to: column)
        return column
    }

    private func terminalColumn() -> NSStackView {
        let column = makeColumn()
        let subtitle = addSection(
            "Terminal bookmarks",
            id: "app1.settings.section.terminal",
            subtitle: "Saved commands that open as terminal tabs.",
            to: column
        )
        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.alignment = .centerY
        addRow.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        addRow.addArrangedSubview(spacer)
        addRow.addArrangedSubview(terminalAddButton)
        column.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        addGroup("Bookmarks", to: column, after: addRow)
        let list = makeCard(padded: false)
        list.stack.addArrangedSubview(terminalListStack)
        terminalListStack.widthAnchor.constraint(equalTo: list.stack.widthAnchor).isActive = true
        addCard(list.host, to: column)
        let warning = addNote(TerminalBookmarkStore.sharingWarning, to: column)
        addGroup("Defaults", to: column, after: warning)
        let defaults = makeCard(padded: false)
        span(makeRow(
            title: "Open in new tab",
            detail: "Replace the current terminal tab when this is off and the bookmark agrees.",
            control: terminalNewTabToggle
        ), in: defaults.stack)
        span(SettingsHairline(), in: defaults.stack)
        span(makeRow(
            title: "Default shell",
            detail: "Used when a bookmark leaves the shell empty.",
            control: terminalShellPopup
        ), in: defaults.stack)
        span(SettingsHairline(), in: defaults.stack)
        span(makeRow(
            title: "Font size",
            detail: "Points, from 11 to 18.",
            control: terminalFontPopup
        ), in: defaults.stack)
        addCard(defaults.host, to: column)
        reloadTerminalBookmarks()
        return column
    }

    @objc private func addTerminalBookmark() {
        presentTerminalEditor(existing: nil)
    }

    @objc private func editTerminalBookmark(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        presentTerminalEditor(existing: terminalBookmarks.bookmark(id: id))
    }

    @objc private func removeTerminalBookmark(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        terminalBookmarks.remove(id: id)
    }

    /// Enabling a reviewed import does not confirm the command and does not start a process.
    @objc private func enableTerminalBookmark(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        terminalBookmarks.setEnabled(true, id: id)
    }

    private func presentTerminalEditor(existing: TerminalBookmark?) {
        let draft = TerminalBookmarkDraft(
            name: existing?.name ?? "",
            command: existing?.command ?? "",
            workingDirectory: existing?.workingDirectory ?? "",
            shell: existing?.shell ?? "",
            openInNewTab: existing?.openInNewTab ?? settings.settings.terminalOpenInNewTab
        )
        let editor = TerminalBookmarkEditor(draft: draft, showsDelete: existing != nil)
        bookmarkEditor = editor
        editor.onSave = { [weak self] draft in
            guard let self else { return }
            if let existing {
                self.terminalBookmarks.update(
                    id: existing.id,
                    name: draft.name,
                    command: draft.command,
                    workingDirectory: draft.workingDirectory,
                    shell: draft.shell,
                    openInNewTab: draft.openInNewTab
                )
            } else {
                _ = self.terminalBookmarks.add(
                    name: draft.name,
                    command: draft.command,
                    workingDirectory: draft.workingDirectory,
                    shell: draft.shell,
                    openInNewTab: draft.openInNewTab
                )
            }
        }
        editor.onDelete = { [weak self] in
            guard let self, let existing else { return }
            self.terminalBookmarks.remove(id: existing.id)
        }
        guard let sheet = editor.window, let host = window else { return }
        host.beginSheet(sheet) { [weak self] _ in
            Task { @MainActor in
                self?.bookmarkEditor = nil
                self?.reloadTerminalBookmarks()
            }
        }
    }

    private func reloadTerminalBookmarks() {
        for view in terminalListStack.arrangedSubviews {
            terminalListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if terminalBookmarks.bookmarks.isEmpty {
            let empty = SettingsLabel(role: .detail, text: "No terminal bookmarks yet")
            empty.translatesAutoresizingMaskIntoConstraints = false
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
                empty.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
                empty.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
                empty.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
                host.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
            ])
            terminalListStack.addArrangedSubview(host)
            host.widthAnchor.constraint(equalTo: terminalListStack.widthAnchor).isActive = true
            return
        }
        for (index, bookmark) in terminalBookmarks.bookmarks.enumerated() {
            if index > 0 {
                let line = SettingsHairline()
                line.translatesAutoresizingMaskIntoConstraints = false
                terminalListStack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: terminalListStack.widthAnchor).isActive = true
            }
            let row = terminalBookmarkRow(bookmark)
            terminalListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: terminalListStack.widthAnchor).isActive = true
        }
    }

    /// Name, the full command in mono, the working directory, and edit/delete. A disabled import can be enabled here.
    private func terminalBookmarkRow(_ bookmark: TerminalBookmark) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false

        let glyph = GlyphView()
        glyph.glyph = .terminal
        glyph.tint = Theme.termGlyph
        glyph.pointSize = 14
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let name = SettingsLabel(role: .rowTitle, text: bookmark.name)
        name.lineBreakMode = .byTruncatingTail

        let command = NSTextField(labelWithString: bookmark.command)
        command.font = Theme.mono(size: 12)
        command.textColor = SettingsContrast.mute
        command.lineBreakMode = .byTruncatingMiddle
        command.maximumNumberOfLines = 1
        command.cell?.wraps = false
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        command.toolTip = bookmark.workingDirectory.isEmpty
            ? bookmark.command
            : bookmark.command + "\n" + bookmark.workingDirectory
        command.setAccessibilityValue(bookmark.command)

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
            directory.setAccessibilityValue(bookmark.workingDirectory)
            directory.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            words.addArrangedSubview(directory)
        }
        if !bookmark.enabled {
            let note = NSTextField(labelWithString: "Disabled until you review it")
            note.font = Theme.font(size: 12)
            note.textColor = SettingsContrast.mute
            let enable = DepthButton(title: "Enable", kind: .secondary)
            styleSettingsButton(enable)
            enable.target = self
            enable.action = #selector(enableTerminalBookmark(_:))
            enable.identifier = NSUserInterfaceItemIdentifier(bookmark.id.uuidString)
            enable.setAccessibilityLabel("Enable")
            let noteRow = NSStackView(views: [note, enable])
            noteRow.orientation = .horizontal
            noteRow.alignment = .centerY
            noteRow.spacing = 8
            words.addArrangedSubview(noteRow)
        }

        let edit = terminalIconButton(.pencil, "Edit", bookmark.id, #selector(editTerminalBookmark(_:)))
        let delete = terminalIconButton(.trash, "Delete", bookmark.id, #selector(removeTerminalBookmark(_:)))
        let actions = NSStackView(views: [edit, delete])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let line = NSStackView(views: [glyph, words, spacer, actions])
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
            edit.widthAnchor.constraint(equalToConstant: 28),
            edit.heightAnchor.constraint(equalToConstant: 28),
            delete.widthAnchor.constraint(equalToConstant: 28),
            delete.heightAnchor.constraint(equalToConstant: 28),
            line.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        return host
    }

    private func terminalIconButton(_ glyph: IconGlyph, _ label: String, _ id: UUID, _ action: Selector) -> ToolButton {
        let button = ToolButton()
        button.glyph = glyph
        button.pointSize = 13
        button.tint = Theme.mute
        button.target = self
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func terminalDefaultsChanged() {
        guard !applying else { return }
        settings.update { value in
            value.terminalOpenInNewTab = terminalNewTabToggle.state == .on
            value.terminalShell = terminalShellPopup.selectedItem?.representedObject as? String ?? ""
            if let title = terminalFontPopup.titleOfSelectedItem, let size = Double(title) {
                value.terminalFontSize = size
            }
        }
    }

    private func makeColumn() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        return column
    }

    private func makeScroll(column: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scroll.documentView = document
        let clip = scroll.contentView
        let padH = SettingsLayout.paddingH
        let maxWidth = SettingsLayout.contentMaxWidth
        let preferred = column.widthAnchor.constraint(equalToConstant: maxWidth)
        preferred.priority = .defaultHigh
        let fill = column.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -(padH * 2))
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: SettingsLayout.topInset),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -SettingsLayout.paddingV),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: padH),
            column.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: -(padH * 2)),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            preferred,
            fill
        ])
        return scroll
    }

    private func addSection(_ title: String, id: String, subtitle: String, to column: NSStackView) -> NSView {
        let heading = SettingsLabel(role: .section, text: title)
        heading.setAccessibilityIdentifier(id)
        let sub = SettingsLabel(role: .subtitle, text: subtitle)
        column.addArrangedSubview(heading)
        column.setCustomSpacing(SettingsLayout.titleToSubtitle, after: heading)
        column.addArrangedSubview(sub)
        column.setCustomSpacing(SettingsLayout.afterSubtitle, after: sub)
        heading.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
        sub.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return sub
    }

    private func addGroup(_ title: String, id: String? = nil, to column: NSStackView, after previous: NSView) {
        let label = SettingsLabel(role: .group, text: title)
        if let id {
            label.setAccessibilityIdentifier(id)
        }
        column.addArrangedSubview(label)
        column.setCustomSpacing(SettingsLayout.groupTop, after: previous)
        column.setCustomSpacing(SettingsLayout.groupBottom, after: label)
    }

    private func addCard(_ host: NSView, to column: NSStackView) {
        column.addArrangedSubview(host)
        host.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    @discardableResult
    private func addNote(_ text: String, to column: NSStackView) -> NSView {
        let label = SettingsLabel(role: .note, text: text)
        column.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return label
    }

    private func makeCard(padded: Bool) -> (host: NSView, stack: NSStackView) {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let fill = SettingsCardFill()
        fill.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(fill)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        let inset: CGFloat = padded ? 14 : 0
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            fill.topAnchor.constraint(equalTo: host.topAnchor),
            fill.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -inset)
        ])
        return (host, stack)
    }

    private func makeRow(
        title: String,
        titleID: String? = nil,
        detail: String? = nil,
        detailLabel: SettingsLabel? = nil,
        control: NSView
    ) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = SettingsLabel(role: .rowTitle, text: title)
        if let titleID {
            titleLabel.setAccessibilityIdentifier(titleID)
        }
        let words = NSStackView()
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        words.translatesAutoresizingMaskIntoConstraints = false
        words.addArrangedSubview(titleLabel)
        let detailView: SettingsLabel?
        if let detailLabel {
            detailView = detailLabel
        } else if let detail {
            detailView = SettingsLabel(role: .detail, text: detail)
        } else {
            detailView = nil
        }
        if let detailView {
            words.addArrangedSubview(detailView)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = NSStackView(views: [words, spacer, control])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 12
        line.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(line)
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        return host
    }

    /// Card stacks align leading, so a row keeps its intrinsic width unless it is pinned.
    private func span(_ view: NSView, in stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func show(_ pane: SettingsPane) {
        guard SettingsPane.installed.contains(pane) else { return }
        currentPane = pane
        if pane == .general {
            loadImportIfNeeded()
        }
        for item in SettingsPane.installed {
            guard let view = paneViews[item] else { continue }
            if item == pane {
                guard view.superview == nil else { continue }
                view.translatesAutoresizingMaskIntoConstraints = false
                contentHost.addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                    view.topAnchor.constraint(equalTo: contentHost.topAnchor),
                    view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
                ])
            } else if view.superview != nil {
                view.removeFromSuperview()
            }
        }
        for button in navButtons {
            button.chosen = button.pane == pane
        }
    }

    private func movePane(by delta: Int) {
        let panes = SettingsPane.installed
        guard let index = panes.firstIndex(of: currentPane) else { return }
        let next = panes[(index + delta + panes.count) % panes.count]
        show(next)
        if let button = navButtons.first(where: { $0.pane == next }) {
            window?.makeFirstResponder(button)
        }
    }

    @objc private func navTapped(_ sender: NSButton) {
        guard let button = sender as? SettingsNavButton else { return }
        show(button.pane)
    }

    private func loadImportIfNeeded() {
        guard !importScanned else { return }
        importScanned = true
        importProfiles = BrowserDetector.scan(home: FileManager.default.homeDirectoryForCurrentUser)
        reloadImportList()
    }

    private func reloadImportList() {
        for view in importStack.arrangedSubviews {
            importStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if importProfiles.isEmpty {
            let choose = DepthButton(title: "Choose file…", kind: .secondary)
            styleSettingsButton(choose)
            choose.target = self
            choose.action = #selector(importBookmarks)
            choose.setAccessibilityIdentifier("app1.settings.import")
            choose.setAccessibilityLabel("Import bookmarks")
            importStack.addArrangedSubview(makeRow(
                title: "No other browsers found on this Mac",
                detail: nil,
                control: choose
            ))
            pinImportRows()
            return
        }
        var assignedID = false
        for profile in importProfiles {
            if importStack.arrangedSubviews.isEmpty == false {
                importStack.addArrangedSubview(SettingsHairline())
            }
            let button = DepthButton(title: "Import", kind: .secondary)
            styleSettingsButton(button)
            button.target = self
            button.action = #selector(importBookmarks)
            button.setAccessibilityLabel("Import bookmarks")
            if !assignedID {
                button.setAccessibilityIdentifier("app1.settings.import")
                assignedID = true
            }
            let name = importTitle(profile)
            let title: String
            let subtitle: String?
            if profile.needsPermission {
                title = "\(name) — needs permission"
                subtitle = "Bookmarks are not read until you allow access."
            } else {
                let count = BrowserDetector.preview(profile)?.bookmarkCount ?? 0
                title = "\(name) — \(grouped(count)) bookmarks"
                subtitle = nil
            }
            importStack.addArrangedSubview(makeRow(title: title, detail: subtitle, control: button))
        }
        pinImportRows()
    }

    /// Row title matches the setup list: "Name — N bookmarks" or "Name — needs permission".
    private func importTitle(_ profile: DetectedProfile) -> String {
        let label = profile.browser.displayName
        let duplicates = importProfiles.filter { $0.browser == profile.browser }.count
        if duplicates > 1, !profile.name.isEmpty, profile.name != label {
            return "\(label) (\(profile.name))"
        }
        return label
    }

    private func pinImportRows() {
        for view in importStack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: importStack.widthAnchor).isActive = true
        }
    }

    private func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func reloadPermissions() {
        let wasApplying = applying
        applying = true
        for view in permissionsStack.arrangedSubviews {
            permissionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let origins = SitePermissionPolicy.listedOrigins(
            mediaOrigins: mediaPermissions.entries.map(\.origin),
            siteOrigins: sitePermissions.origins
        )
        if origins.isEmpty {
            permissionsStack.addArrangedSubview(paddedLine("No stored site permissions."))
        } else {
            for origin in origins {
                if permissionsStack.arrangedSubviews.isEmpty == false {
                    permissionsStack.addArrangedSubview(SettingsHairline())
                }
                permissionsStack.addArrangedSubview(siteHeader(origin))
                for kind in SitePermissionKind.allCases {
                    permissionsStack.addArrangedSubview(SettingsHairline())
                    permissionsStack.addArrangedSubview(permissionChoiceRow(origin: origin, kind: kind))
                }
            }
        }
        if permissionsStack.arrangedSubviews.isEmpty == false {
            permissionsStack.addArrangedSubview(SettingsHairline())
        }
        permissionsStack.addArrangedSubview(makeRow(title: "Stored choices", detail: nil, control: removeAllButton))
        for view in permissionsStack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: permissionsStack.widthAnchor).isActive = true
        }
        applying = wasApplying
    }

    private func paddedLine(_ text: String) -> NSView {
        let label = SettingsLabel(role: .detail, text: text)
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -14),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        return host
    }

    private func siteHeader(_ origin: String) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let words = NSStackView()
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        words.translatesAutoresizingMaskIntoConstraints = false
        let originLabel = NSTextField(labelWithString: origin)
        originLabel.font = Theme.mono(size: 11)
        originLabel.textColor = Theme.text
        originLabel.lineBreakMode = .byTruncatingMiddle
        originLabel.maximumNumberOfLines = 1
        originLabel.cell?.wraps = false
        originLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        originLabel.setAccessibilityLabel(origin)
        words.addArrangedSubview(originLabel)
        if let combined = mediaPermissions.decision(origin: origin, kind: .both) {
            let text = combined == .alwaysAllow
                ? "Camera and microphone together: Always allow"
                : "Camera and microphone together: Always deny"
            words.addArrangedSubview(SettingsLabel(role: .detail, text: text))
        }
        let remove = DepthButton(title: "Remove", kind: .secondary)
        styleSettingsButton(remove)
        remove.target = self
        remove.action = #selector(removeSitePermissions(_:))
        remove.identifier = NSUserInterfaceItemIdentifier(origin)
        remove.setAccessibilityLabel("Remove")
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let line = NSStackView(views: [words, spacer, remove])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 12
        line.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(line)
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        return host
    }

    private func permissionChoiceRow(origin: String, kind: SitePermissionKind) -> NSView {
        let popup = SitePermissionPopup()
        popup.origin = origin
        popup.kind = kind
        popup.removeAllItems()
        for choice in [SitePermissionChoice.ask, .allow, .block] {
            popup.addItem(withTitle: SitePermissionPolicy.title(choice))
            popup.lastItem?.representedObject = choice.rawValue
        }
        let stored = storedChoice(origin: origin, kind: kind)
        let shown = SitePermissionPolicy.displayedChoice(stored: stored, kind: kind)
        popup.selectItem(withTitle: SitePermissionPolicy.title(shown))
        popup.target = self
        popup.action = #selector(sitePermissionChanged(_:))
        popup.setAccessibilityLabel("\(permissionTitle(kind)), \(origin)")
        popup.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let detail: String?
        if kind == .autoplay {
            detail = "New tabs for this site. An open tab keeps its current setting."
        } else if !SitePermissionPolicy.canApplyInWebKit(kind) {
            detail = "Saved only. The page is not granted access."
        } else {
            detail = nil
        }
        return makeRow(title: permissionTitle(kind), detail: detail, control: popup)
    }

    private func storedChoice(origin: String, kind: SitePermissionKind) -> SitePermissionChoice? {
        switch kind {
        case .camera:
            return SitePermissionPolicy.choice(for: mediaPermissions.decision(origin: origin, kind: .camera))
        case .microphone:
            return SitePermissionPolicy.choice(for: mediaPermissions.decision(origin: origin, kind: .microphone))
        case .location, .notifications, .popups, .autoplay:
            return sitePermissions.storedChoice(origin: origin, kind: kind)
        }
    }

    private func permissionTitle(_ kind: SitePermissionKind) -> String {
        switch kind {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .location: return "Location"
        case .notifications: return "Notifications"
        case .popups: return "Pop-ups"
        case .autoplay: return "Autoplay"
        }
    }

    @objc private func sitePermissionChanged(_ sender: NSPopUpButton) {
        guard !applying, let popup = sender as? SitePermissionPopup else { return }
        guard let raw = popup.selectedItem?.representedObject as? String,
              let choice = SitePermissionChoice(rawValue: raw) else {
            return
        }
        let origin = popup.origin
        switch popup.kind {
        case .camera:
            writeMedia(choice, origin: origin, kind: .camera)
        case .microphone:
            writeMedia(choice, origin: origin, kind: .microphone)
        case .location, .notifications, .popups, .autoplay:
            sitePermissions.set(choice, origin: origin, kind: popup.kind)
        }
    }

    /// Ask revokes the stored device choice so the next capture prompt is unchanged.
    private func writeMedia(_ choice: SitePermissionChoice, origin: String, kind: MediaCaptureKind) {
        if let decision = SitePermissionPolicy.mediaDecision(for: choice) {
            mediaPermissions.set(decision, origin: origin, kind: kind)
        } else {
            mediaPermissions.revoke(origin: origin, kind: kind)
        }
    }

    @objc private func removeSitePermissions(_ sender: NSButton) {
        guard let origin = sender.identifier?.rawValue, !origin.isEmpty else { return }
        mediaPermissions.revoke(origin: origin, kind: .camera)
        mediaPermissions.revoke(origin: origin, kind: .microphone)
        mediaPermissions.revoke(origin: origin, kind: .both)
        sitePermissions.remove(origin: origin)
    }

    @objc private func removeAllPermissions() {
        mediaPermissions.removeAll()
        sitePermissions.removeAll()
    }

    private func reloadFromStore() {
        let current = settings.settings
        applying = true
        systemChoice.state = current.appearance == .system ? .on : .off
        lightChoice.state = current.appearance == .light ? .on : .off
        darkChoice.state = current.appearance == .dark ? .on : .off
        systemChoice.refreshAccessibility()
        lightChoice.refreshAccessibility()
        darkChoice.refreshAccessibility()
        systemChoice.needsDisplay = true
        lightChoice.needsDisplay = true
        darkChoice.needsDisplay = true
        // On means hidden. The stored flags stay `hideWebTabs` / `hideTerminalTabs`.
        // One of web or terminal must stay visible, so turning one on disables the other.
        hideWebToggle.state = current.hideWebTabs ? .on : .off
        hideTerminalToggle.state = current.hideTerminalTabs ? .on : .off
        hideWebToggle.isEnabled = !current.hideTerminalTabs
        hideTerminalToggle.isEnabled = !current.hideWebTabs
        hideWebToggle.needsDisplay = true
        hideTerminalToggle.needsDisplay = true
        netHealthToggle.state = current.netHealthEnabled ? .on : .off
        hardwareAccelerationToggle.state = current.hardwareAcceleration ? .on : .off
        netHealthToggle.needsDisplay = true
        let selectedID = current.searchEngineID
        for tile in engineTiles {
            let on = tile.engineID == selectedID
                || (tile.engineID == SearchEngine.duckDuckGo.id && SearchEngine.builtIn(id: selectedID) == nil && selectedID != SearchEngine.customID)
            tile.state = on ? .on : .off
            tile.refreshAccessibility()
            tile.needsDisplay = true
        }
        templateField.stringValue = current.customSearchTemplate
        terminalNewTabToggle.state = current.terminalOpenInNewTab ? .on : .off
        terminalNewTabToggle.needsDisplay = true
        let shellValue = current.terminalShell
        var shellIndex = 0
        for (index, item) in terminalShellPopup.itemArray.enumerated() {
            if (item.representedObject as? String) == shellValue {
                shellIndex = index
                break
            }
        }
        terminalShellPopup.selectItem(at: shellIndex)
        let fontTitle = String(Int(current.terminalFontSize.rounded()))
        if current.terminalFontSize == current.terminalFontSize.rounded(),
           terminalFontPopup.item(withTitle: fontTitle) != nil {
            terminalFontPopup.selectItem(withTitle: fontTitle)
        } else {
            terminalFontPopup.selectItem(withTitle: "13")
        }
        selectRepresented(current.cookiePolicy.rawValue, in: cookiePolicyPopup)
        selectRepresented(current.startupPage.rawValue, in: startupPagePopup)
        startupURLField.stringValue = current.startupURL
        startupURLField.isEnabled = current.startupPage == .customURL
        startupURLFrame.needsDisplay = true
        selectPopup(tag: current.defaultFontSize, in: fontSizePopup, fallback: 16)
        selectPopup(tag: current.defaultZoomPercent, in: zoomPopup, fallback: 100)
        askDownloadsToggle.state = current.askWhereToSaveDownloads ? .on : .off
        openAfterDownloadToggle.state = current.openAfterDownload ? .on : .off
        askDownloadsToggle.needsDisplay = true
        openAfterDownloadToggle.needsDisplay = true
        chooseDownloadsButton.isEnabled = !AppLocations.isDownloadsDirectoryOverridden
        downloadsPathLabel.plain = downloadsDisplayPath()
        applying = false
        refreshNote()
    }

    private func selectRepresented(_ raw: String, in popup: NSPopUpButton) {
        let index = popup.itemArray.firstIndex { ($0.representedObject as? String) == raw } ?? 0
        popup.selectItem(at: index)
    }

    private func selectPopup(tag: Int, in popup: NSPopUpButton, fallback: Int) {
        if popup.item(withTag: tag) != nil {
            popup.selectItem(withTag: tag)
        } else if popup.item(withTag: fallback) != nil {
            popup.selectItem(withTag: fallback)
        }
    }

    private func downloadsDisplayPath() -> String {
        if AppLocations.isDownloadsDirectoryOverridden {
            return AppLocations.downloadsDirectory.path
        }
        let path = settings.settings.downloadsDirectoryPath
        if path.isEmpty {
            return AppLocations.downloadsDirectory.path
        }
        return path
    }

    private func refreshNote() {
        let customSelected = engineTiles.first { $0.state == .on }?.engineID == SearchEngine.customID
        templateField.isEnabled = customSelected
        templateFrame.needsDisplay = true
        if customSelected && SearchEngine.custom(template: templateField.stringValue) == nil {
            noteLabel.plain = "The custom template must be an https address and include {query}. Until it is valid, DuckDuckGo is used."
        } else {
            noteLabel.plain = "Search can be changed at any time."
        }
    }

    /// The clicked radio is already on. Save, then apply `NSApp.appearance` now.
    @objc private func appearancePicked(_ sender: NSButton) {
        let preference: AppearancePreference
        if sender === systemChoice {
            preference = .system
        } else if sender === lightChoice {
            preference = .light
        } else {
            preference = .dark
        }
        settings.update { $0.appearance = preference }
        AppearanceController.apply(preference)
        NotificationCenter.default.post(name: .app1SettingsDidChange, object: settings)
        reloadFromStore()
    }

    @objc private func hideWebChanged() {
        settings.update { value in
            value.hideWebTabs = hideWebToggle.state == .on
        }
        reloadFromStore()
    }

    @objc private func hideTerminalChanged() {
        settings.update { value in
            value.hideTerminalTabs = hideTerminalToggle.state == .on
        }
        reloadFromStore()
    }

    @objc private func hardwareAccelerationChanged() {
        settings.update { $0.hardwareAcceleration = hardwareAccelerationToggle.state == .on }
    }

    @objc private func cookiePolicyChanged() {
        guard !applying else { return }
        let raw = cookiePolicyPopup.selectedItem?.representedObject as? String
        let policy = raw.flatMap(CookiePolicy.init(rawValue:)) ?? .allowAll
        settings.update { $0.cookiePolicy = policy }
    }

    @objc private func startupPageChanged() {
        guard !applying else { return }
        let raw = startupPagePopup.selectedItem?.representedObject as? String
        let page = raw.flatMap(StartupPage.init(rawValue:)) ?? .newTab
        settings.update { $0.startupPage = page }
        reloadFromStore()
    }

    @objc private func startupURLEdited() {
        saveStartupURL()
    }

    private func saveStartupURL() {
        guard !applying else { return }
        settings.update { $0.startupURL = startupURLField.stringValue }
    }

    @objc private func fontSizeChanged() {
        guard !applying else { return }
        let size = fontSizePopup.selectedItem?.tag ?? 16
        settings.update { $0.defaultFontSize = size }
    }

    @objc private func zoomChanged() {
        guard !applying else { return }
        let percent = zoomPopup.selectedItem?.tag ?? 100
        settings.update { $0.defaultZoomPercent = percent }
    }

    @objc private func askDownloadsChanged() {
        guard !applying else { return }
        settings.update { $0.askWhereToSaveDownloads = askDownloadsToggle.state == .on }
    }

    @objc private func openAfterDownloadChanged() {
        guard !applying else { return }
        settings.update { $0.openAfterDownload = openAfterDownloadToggle.state == .on }
    }

    @objc private func chooseDownloadsFolder() {
        guard !AppLocations.isDownloadsDirectoryOverridden, let host = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where downloads are saved"
        panel.directoryURL = URL(fileURLWithPath: downloadsDisplayPath(), isDirectory: true)
        panel.beginSheetModal(for: host) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settings.update { $0.downloadsDirectoryPath = url.path }
            self?.reloadFromStore()
        }
    }

    @objc private func manageSiteData() {
        let sheet = SiteDataSheetController()
        siteDataSheet = sheet
        guard let host = window, let sheetWindow = sheet.window else { return }
        host.beginSheet(sheetWindow) { [weak self] _ in
            Task { @MainActor in
                self?.siteDataSheet = nil
            }
        }
    }

    @objc private func netHealthChanged() {
        settings.update { $0.netHealthEnabled = netHealthToggle.state == .on }
    }

    @objc private func enginePicked(_ sender: NSButton) {
        guard !applying, let tile = sender as? SettingsEngineTile else { return }
        for other in engineTiles {
            other.state = other === tile ? .on : .off
            other.refreshAccessibility()
            other.needsDisplay = true
        }
        saveEngine(selectedID: tile.engineID)
    }

    @objc private func templateEdited() {
        saveEngine()
    }

    @objc private func importBookmarks() {
        NSApp.sendAction(#selector(AppDelegate.importBookmarks(_:)), to: nil, from: self)
    }

    @objc private func checkUpdates() {
        updater?.start(from: window)
    }

    /// macOS 12+ completion API, called for http then https. The status label shows the result.
    @objc private func makeDefaultBrowser() {
        let appURL = Bundle.main.bundleURL
        defaultBrowserStatus.colorOverride = nil
        defaultBrowserStatus.plain = "Setting the default browser…"
        Task { @MainActor in
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http")
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https")
                defaultBrowserStatus.colorOverride = nil
                defaultBrowserStatus.plain = "\(AppInfo.displayName) is the default browser for web links."
            } catch {
                defaultBrowserStatus.colorOverride = Theme.destructive
                defaultBrowserStatus.plain = "Could not make \(AppInfo.displayName) the default browser. \(error.localizedDescription)"
            }
        }
    }

    private func reloadUpdateSource() {
        guard let store = updater?.sourceStore else {
            feedURLField.isEnabled = false
            keyField.isEnabled = false
            saveSourceButton.isEnabled = false
            resetSourceButton.isEnabled = false
            copyKeyButton.isEnabled = false
            showSourceStatus("Updates are not available.", isError: true)
            return
        }
        feedURLField.isEnabled = true
        keyField.isEnabled = true
        saveSourceButton.isEnabled = true
        resetSourceButton.isEnabled = true
        copyKeyButton.isEnabled = true
        if store.hasCustomSource {
            switch store.current() {
            case .success(let source):
                feedURLField.stringValue = source.feedURL.absoluteString
                keyField.stringValue = source.publicKey.encoded
                showSourceStatus("Custom source · key ID \(source.keyFingerprint)", isError: false)
            case .failure(let error):
                feedURLField.stringValue = ""
                keyField.stringValue = ""
                showSourceStatus(
                    "The saved custom source cannot be used: \(UpdateUserMessage.text(for: error)) Enter it again or reset to default.",
                    isError: true
                )
            }
            return
        }
        feedURLField.stringValue = store.builtInURLText
        keyField.stringValue = store.builtInKeyText
        switch store.builtIn() {
        case .success(let source):
            showSourceStatus("Built-in source · key ID \(source.keyFingerprint)", isError: false)
        case .failure(let error):
            showSourceStatus(UpdateUserMessage.text(for: error), isError: true)
        }
    }

    private func showSourceStatus(_ text: String, isError: Bool) {
        sourceStatus.plain = text
        sourceStatus.colorOverride = isError ? Theme.destructive : nil
    }

    /// Both fields are validated together; a source is never saved without its key.
    @objc private func saveUpdateSource() {
        guard let store = updater?.sourceStore else { return }
        let urlText = feedURLField.stringValue
        let keyText = keyField.stringValue
        let checked = UpdateSourceValidator.validate(
            urlText: urlText,
            keyText: keyText,
            origin: .custom,
            allowsDevHTTP: isDevUpdaterCompiled
        )
        guard case .success(let source) = checked else {
            if case .failure(let error) = checked {
                showSourceStatus(UpdateUserMessage.text(for: error), isError: true)
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Use this update source?"
        alert.informativeText = "Updates will be downloaded from \(source.feedURL.host ?? "this address") and installed only when signed by key ID \(source.keyFingerprint). Use a source and key only from someone you trust."
        alert.addButton(withTitle: "Use This Source")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch store.saveCustom(urlText: urlText, keyText: keyText) {
        case .success:
            reloadUpdateSource()
        case .failure(let error):
            showSourceStatus(UpdateUserMessage.text(for: error), isError: true)
        }
    }

    @objc private func resetUpdateSource() {
        updater?.sourceStore.resetToDefault()
        reloadUpdateSource()
    }

    @objc private func copyUpdateKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(keyField.stringValue, forType: .string)
    }

    private func saveEngine(selectedID: String? = nil) {
        guard !applying else { return }
        let id = selectedID ?? engineTiles.first { $0.state == .on }?.engineID
        guard let id else { return }
        settings.update { value in
            if id == SearchEngine.customID {
                value.searchEngineID = SearchEngine.customID
                value.customSearchTemplate = templateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                value.searchEngineID = id
            }
        }
        refreshNote()
    }

    @objc private func clearBrowsingData() {
        guard !clearing else { return }
        let alert = NSAlert()
        alert.messageText = "Clear Browsing Data?"
        alert.informativeText = "Site data stored by the system web view will be removed, along with cached icons. Bookmarks are kept."
        alert.addButton(withTitle: "Clear Browsing Data")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clearing = true
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0)) { [weak self] in
            Task { @MainActor in
                FaviconService.shared.clear()
                self?.clearing = false
                let done = NSAlert()
                done.messageText = "Browsing data cleared"
                done.informativeText = "Bookmarks were kept."
                done.addButton(withTitle: "OK")
                done.runModal()
            }
        }
    }

    @objc private func deleteAllBookmarks() {
        let alert = NSAlert()
        alert.messageText = "Delete all bookmarks?"
        alert.informativeText = "This removes every bookmark and folder. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete All Bookmarks")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        bookmarks.removeAll()
    }

    private func refreshContrast() {
        var roots: [NSView] = []
        if let content = window?.contentView {
            roots.append(content)
        }
        for view in paneViews.values where view.superview == nil {
            roots.append(view)
        }
        for root in roots {
            refreshView(root)
        }
    }

    private func refreshView(_ view: NSView) {
        if let label = view as? SettingsLabel {
            label.rebuild()
        }
        view.needsDisplay = true
        for child in view.subviews {
            refreshView(child)
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handleKey(event)
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, event.keyCode == 53 else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            return event
        }
        if window?.attachedSheet != nil { return event }
        if event.window?.firstResponder is NSTextView { return event }
        window?.performClose(nil)
        return nil
    }

    /// Centers system buttons in the sidebar's top band. Does not retag them.
    private func centerLights() {
        guard !positioningLights, let window else { return }
        let close = window.standardWindowButton(.closeButton)
        let miniaturize = window.standardWindowButton(.miniaturizeButton)
        let zoom = window.standardWindowButton(.zoomButton)
        let fullscreen = window.styleMask.contains(.fullScreen)
        let titled = window.styleMask.contains(.titled)
        let buttonsHidden = close?.isHidden == true || close?.superview?.isHidden == true
        if close == nil || fullscreen || !titled || buttonsHidden {
            return
        }
        guard let close else { return }
        positioningLights = true
        defer { positioningLights = false }
        let band = lightBand.convert(lightBand.bounds, to: nil)
        guard band.height > 2 else { return }
        let buttons = [close, miniaturize, zoom].compactMap { $0 }
        var seen: [NSView] = []
        for button in buttons {
            guard let host = button.superview else { continue }
            if seen.contains(where: { $0 === host }) { continue }
            seen.append(host)
            let buttonInWindow = button.convert(button.bounds, to: nil)
            let delta = band.midY - buttonInWindow.midY
            guard abs(delta) > 0.5, let parent = host.superview else { continue }
            let originInWindow = parent.convert(host.frame.origin, to: nil)
            let moved = NSPoint(x: originInWindow.x, y: originInWindow.y + delta)
            host.setFrameOrigin(parent.convert(moved, from: nil))
        }
    }
}

// MARK: - Drawing

@MainActor
private final class SettingsSidebar: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.fillBarGradient(in: bounds)
        let width = SettingsContrast.lineWidth
        Theme.line.setFill()
        NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SettingsNavButton: NSButton {
    let pane: SettingsPane
    var onMove: ((Int) -> Void)?
    var chosen = false {
        didSet { needsDisplay = true }
    }

    init(pane: SettingsPane) {
        self.pane = pane
        super.init(frame: .zero)
        title = pane.title
        isBordered = false
        focusRingType = .none
        font = Theme.font(size: 12.5)
        setAccessibilityIdentifier("app1.settings.nav.\(pane.navID)")
        setAccessibilityLabel(pane.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 126 {
            onMove?(-1)
            return
        }
        if event.keyCode == 125 {
            onMove?(1)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if chosen {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
            Theme.fillRaisedTab(top: Theme.tabA1, bottom: Theme.tabA2, path: path, in: bounds)
        }
        let ink = chosen ? Theme.text : SettingsContrast.mute
        let glyph = NSRect(x: 9, y: bounds.midY - 7, width: 14, height: 14)
        IconDrawing.stroke(pane.glyph, in: glyph, color: ink)
        let font = Theme.font(size: 12.5, weight: chosen ? .semibold : .regular)
        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: ink
        ])
        let size = text.size()
        let rect = NSRect(x: 32, y: bounds.midY - size.height / 2, width: max(0, bounds.width - 40), height: size.height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin])
        if window?.firstResponder === self {
            Theme.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SettingsAppIcon: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 12
        shadow.set()
        Theme.card.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image = NSApp.applicationIconImage {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
final class SettingsLabel: NSTextField {
    enum Role {
        case section
        case subtitle
        case group
        case headerTitle
        case headerSubtitle
        case rowTitle
        case detail
        case note
    }

    let role: Role
    var plain: String {
        didSet { rebuild() }
    }
    var colorOverride: NSColor? {
        didSet { rebuild() }
    }

    private var wraps: Bool {
        switch role {
        case .subtitle, .detail, .note: return true
        default: return false
        }
    }

    init(role: Role, text: String) {
        self.role = role
        self.plain = text
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        isBordered = false
        backgroundColor = .clear
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func rebuild() {
        let displayed: String
        let size: CGFloat
        let weight: NSFont.Weight
        let color: NSColor
        let kern: CGFloat
        switch role {
        case .section:
            displayed = plain
            size = 20
            weight = .bold
            color = Theme.text
            kern = -0.2
        case .subtitle:
            displayed = plain
            size = 12.5
            weight = .regular
            color = SettingsContrast.mute
            kern = 0
        case .group:
            displayed = plain.uppercased()
            size = 11
            weight = .semibold
            color = SettingsContrast.mute
            kern = 0.55
        case .headerTitle:
            displayed = plain
            size = 13
            weight = .bold
            color = Theme.text
            kern = 0
        case .headerSubtitle:
            displayed = plain
            size = 11
            weight = .regular
            color = SettingsContrast.mute
            kern = 0
        case .rowTitle:
            displayed = plain
            size = 13
            weight = .semibold
            color = Theme.text
            kern = 0
        case .detail:
            displayed = plain
            size = 11.5
            weight = .regular
            color = SettingsContrast.mute
            kern = 0
        case .note:
            displayed = plain
            size = 12
            weight = .regular
            color = SettingsContrast.mute
            kern = 0
        }
        let ink = colorOverride ?? color
        let font = Theme.font(size: size, weight: weight)
        self.font = font
        textColor = ink
        if wraps {
            usesSingleLineMode = false
            cell?.wraps = true
            cell?.isScrollable = false
            lineBreakMode = .byWordWrapping
            maximumNumberOfLines = role == .note ? 0 : 6
            if preferredMaxLayoutWidth < 40 {
                preferredMaxLayoutWidth = 360
            }
        } else {
            usesSingleLineMode = true
            cell?.wraps = false
            lineBreakMode = .byTruncatingTail
            maximumNumberOfLines = 1
        }
        attributedStringValue = NSAttributedString(string: displayed, attributes: [
            .font: font,
            .foregroundColor: ink,
            .kern: kern
        ])
        if role == .group {
            setAccessibilityLabel(plain)
        }
    }

    override func layout() {
        super.layout()
        guard wraps, bounds.width > 40 else { return }
        if abs(preferredMaxLayoutWidth - bounds.width) > 2 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }
}

@MainActor
private final class SettingsCardFill: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
final class SettingsHairline: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = SettingsContrast.lineWidth
        Theme.line.setFill()
        NSRect(x: 14, y: bounds.midY - width / 2, width: max(0, bounds.width - 28), height: width).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SettingsFieldFrame: NSView {
    let field = NSTextField(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.mono(size: 12.5)
        field.textColor = Theme.text
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === self ? field : hit
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        FieldFrame.draw(in: bounds, radius: 7)
        if field.currentEditor() != nil {
            Theme.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        field.textColor = Theme.text
        needsDisplay = true
    }
}

@MainActor
private final class SettingsSwitch: NSSwitch {
    init(label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        controlSize = .regular
        applyTint()
        setAccessibilityLabel(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Toggle on mouse-down, matching the other settings controls.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        state = state == .on ? .off : .on
        sendAction(action, to: target)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func applyTint() {
        // NSSwitch has no public tint API on every SDK; set it only where the runtime supports it.
        if responds(to: NSSelectorFromString("setContentTintColor:")) {
            setValue(Theme.accentFill, forKey: "contentTintColor")
        }
    }
}

@MainActor
private final class SettingsThemeChoice: SettingsRadio {
    let preference: AppearancePreference

    init(title: String, preference: AppearancePreference) {
        self.preference = preference
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        setButtonType(.radio)
        refreshAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshAccessibility() {
        let suffix = state == .on ? ", selected" : ""
        setAccessibilityLabel("Theme: \(title)\(suffix)")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        refreshAccessibility()
        needsDisplay = true
    }

    override func performClick(_ sender: Any?) {
        super.performClick(sender)
        refreshAccessibility()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let thumb = NSRect(x: 0, y: bounds.height - 74, width: bounds.width, height: 74)
        let clip = NSBezierPath(roundedRect: thumb, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        switch preference {
        case .light:
            fillPreview(thumb, page: ThemeTokens.light.page, bar: ThemeTokens.light.bar1)
        case .dark:
            fillPreview(thumb, page: ThemeTokens.dark.page, bar: ThemeTokens.dark.bar1)
        case .system:
            let left = NSRect(x: thumb.minX, y: thumb.minY, width: thumb.width / 2, height: thumb.height)
            let right = NSRect(x: thumb.midX, y: thumb.minY, width: thumb.width / 2, height: thumb.height)
            fillPreview(left, page: ThemeTokens.light.page, bar: ThemeTokens.light.bar1)
            fillPreview(right, page: ThemeTokens.dark.page, bar: ThemeTokens.dark.bar1)
        }
        let glyphColor: NSColor
        let glyph: IconGlyph
        switch preference {
        case .light:
            glyph = .sun
            glyphColor = Theme.color(hex: ThemeTokens.light.text)
        case .dark:
            glyph = .moon
            glyphColor = Theme.color(hex: ThemeTokens.dark.text)
        case .system:
            glyph = .sun
            glyphColor = Theme.color(hex: ThemeTokens.light.text)
        }
        if preference == .system {
            IconDrawing.stroke(glyph, in: NSRect(x: thumb.minX + 10, y: thumb.midY - 8, width: 16, height: 16), color: glyphColor)
            IconDrawing.stroke(
                .moon,
                in: NSRect(x: thumb.maxX - 26, y: thumb.midY - 8, width: 16, height: 16),
                color: Theme.color(hex: ThemeTokens.dark.text)
            )
        } else {
            IconDrawing.stroke(
                glyph,
                in: NSRect(x: thumb.midX - 8, y: thumb.midY - 10, width: 16, height: 16),
                color: glyphColor
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(roundedRect: thumb.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        if state == .on {
            Theme.accent.setStroke()
            ring.lineWidth = 2
        } else {
            Theme.line.setStroke()
            ring.lineWidth = SettingsContrast.lineWidth
        }
        ring.stroke()
        let ink = state == .on ? Theme.accent : Theme.text
        let font = Theme.font(size: 12, weight: .semibold)
        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: ink
        ])
        let size = text.size()
        let label = NSRect(
            x: bounds.midX - size.width / 2,
            y: 4,
            width: size.width,
            height: size.height
        )
        text.draw(with: label, options: [.usesLineFragmentOrigin])
        if window?.firstResponder === self {
            Theme.accent.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    private func fillPreview(_ rect: NSRect, page: String, bar: String) {
        Theme.color(hex: page).setFill()
        rect.fill()
        Theme.color(hex: bar).setFill()
        NSRect(x: rect.minX, y: rect.maxY - 14, width: rect.width, height: 14).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SettingsEngineTile: SettingsRadio {
    let engineID: String
    private let badge = LetterBadgeView()
    private let nameLabel = NSTextField(labelWithString: "")

    init(engineID: String, name: String) {
        self.engineID = engineID
        super.init(frame: .zero)
        title = name
        isBordered = false
        focusRingType = .none
        setButtonType(.radio)
        imagePosition = .noImage
        badge.letter = SiteBadge.letter(forTitle: name)
        badge.hex = SiteBadge.colorHex(forHost: name)
        badge.cornerRadius = 6
        badge.fontSize = 12
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setAccessibilityElement(false)
        nameLabel.stringValue = name
        nameLabel.font = Theme.font(size: 11, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.usesSingleLineMode = true
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setAccessibilityElement(false)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(badge)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: SettingsLayout.engineTilePad),
            badge.widthAnchor.constraint(equalToConstant: SettingsLayout.engineBadge),
            badge.heightAnchor.constraint(equalToConstant: SettingsLayout.engineBadge),
            nameLabel.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: SettingsLayout.engineBadgeGap),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -SettingsLayout.engineTilePad)
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshAccessibility()
        applyLabelColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 64, height: SettingsLayout.engineTileHeight)
    }

    func refreshAccessibility() {
        let suffix = state == .on ? ", selected" : ""
        setAccessibilityLabel("Search engine: \(title)\(suffix)")
        applyLabelColor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        refreshAccessibility()
        needsDisplay = true
    }

    override func performClick(_ sender: Any?) {
        super.performClick(sender)
        refreshAccessibility()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        Theme.card.setFill()
        path.fill()
        if state == .on {
            Theme.accent.setStroke()
            path.lineWidth = 2
        } else {
            Theme.line.setStroke()
            path.lineWidth = SettingsContrast.lineWidth
        }
        path.stroke()
        if window?.firstResponder === self {
            Theme.accent.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLabelColor()
        needsDisplay = true
    }

    private func applyLabelColor() {
        nameLabel.textColor = state == .on ? Theme.accent : Theme.text
    }
}

/// Decorative latency row. Not an accessibility element; the real badge stays in the browser window.
@MainActor
private final class SettingsNetPreview: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 230, height: 28) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let field = NSRect(x: 0, y: 0, width: 150, height: bounds.height)
        FieldFrame.draw(in: field, radius: 7)
        IconDrawing.stroke(
            .lock,
            in: NSRect(x: 8, y: bounds.midY - 6, width: 12, height: 12),
            color: SettingsContrast.mute
        )
        let sample = NSAttributedString(string: "example.com", attributes: [
            .font: Theme.mono(size: 11.5),
            .foregroundColor: SettingsContrast.mute
        ])
        let sampleSize = sample.size()
        sample.draw(with: NSRect(
            x: 24,
            y: bounds.midY - sampleSize.height / 2,
            width: 120,
            height: sampleSize.height
        ), options: [.usesLineFragmentOrigin])
        let good = NSAttributedString(string: "Good", attributes: [
            .font: Theme.font(size: 12, weight: .semibold),
            .foregroundColor: Theme.color(hex: "#3DD68C")
        ])
        let goodSize = good.size()
        IconDrawing.stroke(
            .activity,
            in: NSRect(x: 158, y: bounds.midY - 7, width: 14, height: 14),
            color: Theme.color(hex: "#3DD68C")
        )
        good.draw(with: NSRect(
            x: 176,
            y: bounds.midY - goodSize.height / 2,
            width: goodSize.width,
            height: goodSize.height
        ), options: [.usesLineFragmentOrigin])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Flipped document view so a short pane stays at the top of the clip.
@MainActor
private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Menu-backed popup drawn like a 28pt secondary Settings button, with a trailing chevron.
@MainActor
private class SettingsPopUpButton: NSPopUpButton {
    convenience init() {
        self.init(frame: .zero, pullsDown: false)
    }

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyStyle() {
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        font = Theme.font(size: 12.5, weight: .semibold)
        if let popupCell = cell as? NSPopUpButtonCell {
            popupCell.bezelStyle = .regularSquare
            popupCell.isBordered = false
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    override var intrinsicContentSize: NSSize {
        let font = self.font ?? Theme.font(size: 12.5, weight: .semibold)
        let text = ((titleOfSelectedItem ?? title) as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(text.width) + 12 + 8 + 10 + 12, height: 28)
    }

    override func selectItem(at index: Int) {
        super.selectItem(at: index)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        return super.sendAction(action, to: target)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 7
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        if !isEnabled {
            NSGraphicsContext.current?.cgContext.setAlpha(0.45)
        }
        Theme.fillGradient(top: Theme.tabA1, bottom: Theme.tabA2, path: path)
        Theme.fieldLine.setStroke()
        path.lineWidth = SettingsContrast.lineWidth
        path.stroke()
        let font = self.font ?? Theme.font(size: 12.5, weight: .semibold)
        let label = titleOfSelectedItem ?? title
        let rendered = NSAttributedString(string: label, attributes: [
            .font: font,
            .foregroundColor: Theme.text
        ])
        let size = rendered.size()
        let textRect = NSRect(
            x: 12,
            y: bounds.midY - size.height / 2,
            width: max(0, bounds.width - 12 - 22),
            height: size.height
        )
        rendered.draw(with: textRect, options: [.usesLineFragmentOrigin])
        drawChevron()
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self {
            Theme.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: radius, yRadius: radius)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func drawChevron() {
        let cx = bounds.maxX - 14
        let cy = bounds.midY
        // Point the chevron down in either coordinate orientation.
        let d: CGFloat = isFlipped ? -1 : 1
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: cx - 3.5, y: cy + 1.5 * d))
        chevron.line(to: NSPoint(x: cx, y: cy - 2 * d))
        chevron.line(to: NSPoint(x: cx + 3.5, y: cy + 1.5 * d))
        chevron.lineWidth = 1.5
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        Theme.mute.setStroke()
        chevron.stroke()
    }
}

/// Ask / Allow / Block popup for one site and one permission.
private final class SitePermissionPopup: SettingsPopUpButton {
    var origin = ""
    var kind: SitePermissionKind = .camera

    override var intrinsicContentSize: NSSize {
        NSSize(width: 96, height: 28)
    }
}
