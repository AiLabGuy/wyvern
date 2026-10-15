// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, @unchecked Sendable {
    private let bookmarkStore: BookmarkStore
    private let settings: SettingsStore
    private let mediaPermissions: MediaPermissionStore
    private let sitePermissions: SitePermissionStore
    private let terminalBookmarks: TerminalBookmarkStore
    private let launchConfig: LaunchConfiguration
    private let session: SessionCoordinator
    private var windows: [BrowserWindowController] = []
    private var settingsController: SettingsWindowController?
    private var setupController: FirstRunSetupController?
    private var acknowledgementsController: AcknowledgementsController?
    private var updater: AppUpdater?
    private var tabSearch: TabSearchPanelController?
    private var restorePrompt: SessionRestorePrompt?
    private var suppressSessionSaves = false
    private var appliedCookiePolicy: CookiePolicy?
    private var settingsObserver: NSObjectProtocol?
    private let bookmarksMenu = NSMenu(title: "Bookmarks")
    private let terminalMenu = NSMenu(title: "New Terminal Tab")
    private let historyMenu = NSMenu(title: "History")
    private let viewMenu = NSMenu(title: "View")
    private let windowMenu = NSMenu(title: "Window")
    /// Top-level Develop menu. Hidden while Show Develop menu is off.
    private var developMenuItem: NSMenuItem?
    /// Retitled between Show and Hide Web Inspector.
    var showWebInspectorItem: NSMenuItem?
    private var tabKeyMonitor: Any?
    private var didApplyLaunchWindow = false
    /// URLs from `application(_:open:)` before the first browser window exists.
    private var pendingOpenURLs: [URL] = []

    override init() {
        let config = LaunchArguments.parse(Array(CommandLine.arguments))
        if config.bench {
            BenchMarks.enable()
        }
        AppLocations.apply(config)
        AppLocations.migratePersistentStateIfNeeded()
        launchConfig = config
        bookmarkStore = BookmarkStore()
        settings = SettingsStore(defaults: AppLocations.userDefaults)
        mediaPermissions = MediaPermissionStore()
        sitePermissions = SitePermissionStore()
        terminalBookmarks = TerminalBookmarkStore(directory: AppLocations.dataDirectory)
        session = SessionCoordinator(directory: AppLocations.dataDirectory)
        super.init()
        updater = AppUpdater(settings: settings)
    }

    private enum MenuTag {
        static let back = 1
        static let forward = 2
        static let reload = 3
        static let stop = 4
        static let location = 5
        static let bookmark = 6
        static let restoreSession = 7
        static let showBlockedCount = 8
        static let bookmarkSeparator = 900
    }

    private enum WindowSeed {
        /// First window honors `--wyvern-open` and queued URLs. Later windows open a new tab.
        case launch
        case newTab
        case empty
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        BenchMarks.emit("application-did-finish-launching")
        if let appearance = launchConfig.appearance {
            settings.update { $0.appearance = appearance }
        }
        AppearanceController.apply(settings.settings.appearance)
        BrowserTab.hardwareAcceleration = settings.settings.hardwareAcceleration
        BrowserTab.defaultFontSize = settings.settings.defaultFontSize
        BrowserTab.defaultZoomPercent = settings.settings.defaultZoomPercent
        BrowserTab.developerToolsEnabled = settings.settings.developerToolsEnabled
        BrowserTab.logSoftwareRenderingSupport()
        ProcessInfo.processInfo.disableSuddenTermination()
        CookiePolicyController.shared.apply(settings.settings.cookiePolicy)
        appliedCookiePolicy = settings.settings.cookiePolicy
        BlockListController.shared.start()
        wireDownloads()
        observeSettings()
        session.beginRun()
        session.capture = { [weak self] in
            self?.captureOpenSession() ?? SessionSnapshot(windows: [])
        }
        updater?.clearBackupIfNeeded()
        DownloadManager.shared.revealPopoverWhenNonEmpty = launchConfig.showDownloads
        buildMainMenu()
        installTabKeyMonitor()
        launchInitialWindows()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock items do not walk the responder chain, so New Window targets this delegate.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("New Window", action: #selector(newWindow(_:)), target: self))
        return menu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session.finish()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.finish()
        if let tabKeyMonitor {
            NSEvent.removeMonitor(tabKeyMonitor)
            self.tabKeyMonitor = nil
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Cold launch queues until the first window exists; warm launch opens in the frontmost window.
    /// A lone unused new-tab page is reused so a launch with URLs does not leave an extra blank tab.
    func application(_ application: NSApplication, open urls: [URL]) {
        let accepted = urls.filter { Self.isExternalOpenURL($0) }
        guard !accepted.isEmpty else { return }
        if !didApplyLaunchWindow {
            pendingOpenURLs.append(contentsOf: accepted)
            return
        }
        openExternalURLs(accepted)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let browser = keyBrowser
        if menu === historyMenu || menu === viewMenu || menu === bookmarksMenu {
            setEnabled(MenuTag.back, browser?.canGoBack == true, in: menu)
            setEnabled(MenuTag.forward, browser?.canGoForward == true, in: menu)
            setEnabled(MenuTag.reload, browser != nil, in: menu)
            setEnabled(MenuTag.stop, browser?.isLoadingPage == true, in: menu)
            setEnabled(MenuTag.location, browser != nil, in: menu)
            setEnabled(MenuTag.bookmark, browser?.canBookmarkCurrent == true, in: menu)
        }
        if menu === viewMenu, let entry = menu.items.first(where: { $0.tag == MenuTag.showBlockedCount }) {
            entry.state = BlockListController.shared.showBlockedCount ? .on : .off
        }
        if menu === bookmarksMenu {
            rebuildBookmarkItems()
        }
        if menu === terminalMenu {
            rebuildTerminalMenu(menu)
        }
        if menu === developMenuItem?.submenu {
            refreshDevelopMenuTitles()
        }
        if menu === windowMenu {
            if NSApp.keyWindow?.windowController is SettingsWindowController {
                for number in 1...9 {
                    setEnabled(100 + number, number <= SettingsWindowController.installedPaneCount, in: menu)
                }
            } else {
                let count = browser?.tabCount ?? 0
                for number in 1...9 {
                    let enabled = number == 9 ? count > 0 : number <= count
                    setEnabled(100 + number, enabled, in: menu)
                }
            }
        }
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: AppInfo.copyrightNotice + "\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        credits.append(NSAttributedString(
            string: AppInfo.trademarkFootnote,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.displayName,
            .version: AppInfo.marketingVersion,
            .applicationVersion: AppInfo.marketingVersion,
            .credits: credits
        ])
    }

    @objc func showAcknowledgements(_ sender: Any?) {
        if acknowledgementsController == nil {
            acknowledgementsController = AcknowledgementsController()
        }
        acknowledgementsController?.showWindow(sender)
        acknowledgementsController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func newWindow(_ sender: Any?) {
        _ = makeWindow()
    }

    @objc func newTab(_ sender: Any?) {
        if let browser = keyBrowser {
            _ = browser.addTab()
        } else {
            _ = makeWindow()
        }
    }

    /// End of the responder chain for Close Tab. A key browser window handles `closeTab:` itself
    /// (`BrowserWindowController.closeTab(_:)`); this runs for other windows, such as Settings.
    @objc func closeTab(_ sender: Any?) {
        if NSApp.keyWindow?.windowController is BrowserWindowController {
            keyBrowser?.closeActiveTab()
            return
        }
        if let browser = keyBrowser, browser.window === NSApp.keyWindow {
            browser.closeActiveTab()
            return
        }
        NSApp.keyWindow?.performClose(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeTab(_:)):
            return keyBrowser != nil || NSApp.keyWindow != nil
        case #selector(closeWindow(_:)):
            return NSApp.keyWindow != nil
        case #selector(restorePreviousSessionFromMenu(_:)):
            return session.canRestorePrevious
        case #selector(showWebInspector(_:)):
            return focusedBrowserWindow()?.canToggleWebInspector == true
        case #selector(startElementSelection(_:)), #selector(showJavaScriptConsole(_:)):
            return focusedBrowserWindow()?.focusedWebInspectorTarget() != nil
        default:
            return true
        }
    }

    @objc func closeWindow(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    @objc func selectNextTab(_ sender: Any?) {
        keyBrowser?.selectRelativeTab(offset: 1)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        keyBrowser?.selectRelativeTab(offset: -1)
    }

    @objc func goBack(_ sender: Any?) {
        keyBrowser?.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        keyBrowser?.goForward()
    }

    @objc func reloadPage(_ sender: Any?) {
        keyBrowser?.reloadPage()
    }

    @objc func stopLoading(_ sender: Any?) {
        keyBrowser?.stopLoading()
    }

    @objc func focusLocation(_ sender: Any?) {
        keyBrowser?.focusLocationField()
    }

    @objc func addBookmarkFromMenu(_ sender: Any?) {
        keyBrowser?.addBookmark()
    }

    @objc func showAllBookmarks(_ sender: Any?) {
        let browser = keyBrowser ?? makeWindow()
        browser.showBookmarks()
    }

    @objc func importBookmarks(_ sender: Any?) {
        let browser = keyBrowser ?? makeWindow()
        browser.presentBookmarkImport()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                settings: settings,
                bookmarks: bookmarkStore,
                mediaPermissions: mediaPermissions,
                sitePermissions: sitePermissions,
                updater: updater,
                terminalBookmarks: terminalBookmarks
            )
        }
        settingsController?.showWindow(sender)
        settingsController?.window?.makeKeyAndOrderFront(sender)
    }

    func showBlockListSettings(_ sender: Any?) {
        showSettings(sender)
        settingsController?.showBlockList()
    }

    @objc func toggleBlockedCount(_ sender: Any?) {
        let shown = BlockListController.shared.showBlockedCount == false
        BlockListController.shared.setShowBlockedCount(shown)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater?.start(from: keyBrowser?.window)
    }

    /// The setup controller stays retained until its window closes. Button targets are weak.
    private func presentSetup() {
        let controller = FirstRunSetupController(bookmarks: bookmarkStore, settings: settings)
        setupController = controller
        FirstRunSetupController.retain(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            let showTour = controller?.finishedOnDone == true && self.settings.settings.tourSeen == false
            self.settings.update { $0.didOfferFirstImport = true }
            if self.setupController === controller {
                self.setupController = nil
            }
            guard showTour else { return }
            DispatchQueue.main.async { [weak self] in
                self?.showGuidedTour(nil)
            }
        }
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        if let settings = NSApp.keyWindow?.windowController as? SettingsWindowController {
            settings.selectPane(number: item.tag - 100)
            return
        }
        keyBrowser?.selectTab(number: item.tag - 100)
    }

    @objc func openBookmarkFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let id = UUID(uuidString: raw),
              let bookmark = bookmarkStore.bookmark(id: id),
              let url = URL(string: bookmark.url) else {
            return
        }
        let browser = keyBrowser ?? makeWindow()
        browser.loadInActiveTab(url: url, userTypedFile: url.scheme?.lowercased() == "file")
    }

    /// DevTools-only window. 900×640, or the last frame stored under `wyvern.devtools.windowFrame`.
    func presentDevToolsWindow(_ tab: SessionTab) {
        let controller = installWindow()
        controller.shouldCascadeWindows = false
        if let frame = Self.rememberedDevToolsWindowFrame() {
            controller.window?.setFrame(frame, display: false)
        } else {
            controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 640), display: false)
            controller.window?.center()
        }
        controller.showWindow(nil)
        controller.adopt(tab: tab, at: 0)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static let devToolsWindowFrameKey = "wyvern.devtools.windowFrame"

    static func rememberedDevToolsWindowFrame() -> NSRect? {
        guard let raw = AppLocations.userDefaults.string(forKey: devToolsWindowFrameKey) else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] >= 320, parts[3] >= 200 else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    static func rememberDevToolsWindowFrame(_ frame: NSRect) {
        let raw = "\(frame.origin.x),\(frame.origin.y),\(frame.size.width),\(frame.size.height)"
        AppLocations.userDefaults.set(raw, forKey: devToolsWindowFrameKey)
    }

    /// A window for a tab that already exists. No blank tab is added; the caller adopts the live tab.
    func presentDetachedTab(_ tab: SessionTab, dropScreenPoint: NSPoint, cursorOffsetInTab: NSPoint) {
        let controller = installWindow()
        controller.shouldCascadeWindows = false
        controller.placeTabUnderCursor(
            tabID: tab.id,
            dropScreenPoint: dropScreenPoint,
            cursorOffsetInTab: cursorOffsetInTab
        )
        controller.showWindow(nil)
        controller.adopt(tab: tab, at: 0)
        controller.placeTabUnderCursor(
            tabID: tab.id,
            dropScreenPoint: dropScreenPoint,
            cursorOffsetInTab: cursorOffsetInTab
        )
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func installWindow() -> BrowserWindowController {
        let controller = BrowserWindowController(
            bookmarks: bookmarkStore,
            settings: settings,
            mediaPermissions: mediaPermissions,
            sitePermissions: sitePermissions,
            terminalBookmarks: terminalBookmarks
        )
        controller.onPrepareClose = { [weak self] in
            guard let self, !self.suppressSessionSaves else { return }
            self.session.saveNow()
        }
        controller.onSessionChange = { [weak self] in
            guard let self, !self.suppressSessionSaves else { return }
            self.session.scheduleSave()
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windows.removeAll { $0 === controller }
            guard !self.suppressSessionSaves else { return }
            self.session.scheduleSave()
        }
        windows.append(controller)
        return controller
    }

    private func makeWindow(seed: WindowSeed = .launch) -> BrowserWindowController {
        let controller = installWindow()
        let applyLaunch = !didApplyLaunchWindow
        if applyLaunch {
            didApplyLaunchWindow = true
            if let width = launchConfig.windowWidth, let height = launchConfig.windowHeight {
                controller.applyContentSize(width: width, height: height)
            }
            controller.printsWindowIdentity = launchConfig.printWindowID
            controller.opensDownloadsFromHook = launchConfig.showDownloads
        }
        controller.showWindow(nil)
        if applyLaunch {
            controller.armWindowIdentityPrint()
        }
        switch seed {
        case .launch:
            if applyLaunch {
                if let target = launchConfig.openTarget, let url = resolveLaunchURL(target) {
                    controller.open(url)
                } else if pendingOpenURLs.isEmpty {
                    _ = controller.addTab()
                }
            } else {
                _ = controller.addTab()
            }
        case .newTab:
            _ = controller.addTab()
        case .empty:
            break
        }
        if !suppressSessionSaves {
            session.scheduleSave()
        }
        return controller
    }

    private func flushPendingOpenURLs() {
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        guard !urls.isEmpty else { return }
        openExternalURLs(urls)
    }

    private func openExternalURLs(_ urls: [URL]) {
        let browser = keyBrowser ?? windows.last ?? makeWindow()
        for url in urls {
            browser.openInNewTab(url)
        }
    }

    /// http, https, and local HTML documents handed over as the default browser.
    private static func isExternalOpenURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return true
        case "file":
            let ext = url.pathExtension.lowercased()
            return ext == "html" || ext == "htm" || ext == "xhtml" || ext == "url"
        default:
            return false
        }
    }

    /// Launch targets accept internal pages, absolute http(s)/file/about URLs, or address-bar text.
    private func resolveLaunchURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), InternalPage.parse(url) != nil {
            return url
        }
        if let url = URL(string: trimmed) {
            switch url.scheme?.lowercased() {
            case "http", "https", "file", "about":
                return url
            default:
                break
            }
        }
        return InputResolver(engine: settings.settings.resolvedSearchEngine()).resolve(trimmed)
    }

    private var keyBrowser: BrowserWindowController? {
        let key = NSApp.keyWindow
        if let controller = key?.windowController as? BrowserWindowController {
            return controller
        }
        if let parent = key?.sheetParent?.windowController as? BrowserWindowController {
            return parent
        }
        return windows.last
    }

    /// Key browser only. Develop commands do not fall back to another window.
    func focusedBrowserWindow() -> BrowserWindowController? {
        let key = NSApp.keyWindow
        if let controller = key?.windowController as? BrowserWindowController {
            return controller
        }
        if let parent = key?.sheetParent?.windowController as? BrowserWindowController {
            return parent
        }
        return nil
    }

    /// Develop menu actions call this. The tab comes from `focusedWebInspectorTarget()`.
    func developCommandTarget() -> (tab: BrowserTab, window: NSWindow?)? {
        guard let browser = focusedBrowserWindow() else { return nil }
        guard let tab = browser.focusedWebInspectorTarget() else { return nil }
        return (tab, browser.window)
    }

    private func updateDevelopMenuVisibility() {
        developMenuItem?.isHidden = !settings.settings.developerToolsEnabled
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: AppInfo.displayName)
        appItem.submenu = appMenu
        appMenu.addItem(item("About \(AppInfo.displayName)", action: #selector(showAbout(_:)), target: self))
        appMenu.addItem(item("Acknowledgements", action: #selector(showAcknowledgements(_:)), target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", action: #selector(showSettings(_:)), key: ",", target: self))
        appMenu.addItem(item("Check for Updates…", action: #selector(checkForUpdates(_:)), target: self))
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide \(AppInfo.displayName)", action: #selector(NSApplication.hide(_:)), key: "h"))
        appMenu.addItem(item(
            "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            key: "h",
            modifiers: [.command, .option]
        ))
        appMenu.addItem(item("Show All", action: #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit \(AppInfo.displayName)", action: #selector(NSApplication.terminate(_:)), key: "q"))

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(item("New Window", action: #selector(newWindow(_:)), key: "n", target: self))
        fileMenu.addItem(item("New Tab", action: #selector(newTab(_:)), key: "t", target: self))
        let terminalItem = NSMenuItem(title: "New Terminal Tab", action: nil, keyEquivalent: "")
        terminalMenu.delegate = self
        terminalItem.submenu = terminalMenu
        fileMenu.addItem(terminalItem)
        // nil target: Command-W goes down the responder chain to the key window's controller.
        fileMenu.addItem(item("Close Tab", action: #selector(BrowserWindowController.closeTab(_:)), key: "w"))
        fileMenu.addItem(item(
            "Close Window",
            action: #selector(closeWindow(_:)),
            key: "w",
            modifiers: [.command, .shift],
            target: self
        ))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Import Bookmarks…", action: #selector(importBookmarks(_:)), target: self))

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(item("Undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(item(
            "Redo",
            action: Selector(("redo:")),
            key: "z",
            modifiers: [.command, .shift]
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(item("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(item("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(item(
            "Paste and Match Style",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            key: "v",
            modifiers: [.command, .option, .shift]
        ))
        editMenu.addItem(item("Delete", action: #selector(NSText.delete(_:))))
        editMenu.addItem(item("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        viewItem.submenu = viewMenu
        viewMenu.delegate = self
        let reload = item("Reload", action: #selector(reloadPage(_:)), key: "r", target: self)
        reload.tag = MenuTag.reload
        viewMenu.addItem(reload)
        let stop = item("Stop", action: #selector(stopLoading(_:)), key: ".", target: self)
        stop.tag = MenuTag.stop
        viewMenu.addItem(stop)
        viewMenu.addItem(.separator())
        let focus = item("Focus Address Field", action: #selector(focusLocation(_:)), key: "l", target: self)
        focus.tag = MenuTag.location
        viewMenu.addItem(focus)
        viewMenu.addItem(.separator())
        let blockedCount = item("Show Blocked Count", action: #selector(toggleBlockedCount(_:)), target: self)
        blockedCount.tag = MenuTag.showBlockedCount
        blockedCount.state = BlockListController.shared.showBlockedCount ? .on : .off
        viewMenu.addItem(blockedCount)
        viewMenu.addItem(item(
            "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            key: "f",
            modifiers: [.command, .control]
        ))
        viewMenu.addItem(.separator())
        let splitMenu = NSMenu(title: "Split View")
        let splitItem = NSMenuItem(title: "Split View", action: nil, keyEquivalent: "")
        splitItem.submenu = splitMenu
        viewMenu.addItem(splitItem)
        appendSplitCommands(to: splitMenu)
        developMenuItem = installDevelopMenu(on: main)
        updateDevelopMenuVisibility()

        let historyItem = NSMenuItem()
        main.addItem(historyItem)
        historyItem.submenu = historyMenu
        historyMenu.delegate = self
        let back = item("Back", action: #selector(goBack(_:)), key: "[", target: self)
        back.tag = MenuTag.back
        historyMenu.addItem(back)
        let forward = item("Forward", action: #selector(goForward(_:)), key: "]", target: self)
        forward.tag = MenuTag.forward
        historyMenu.addItem(forward)
        historyMenu.addItem(.separator())
        let restoreSession = item(
            "Restore Previous Session",
            action: #selector(restorePreviousSessionFromMenu(_:)),
            target: self
        )
        restoreSession.tag = MenuTag.restoreSession
        historyMenu.addItem(restoreSession)

        let bookmarksItem = NSMenuItem()
        main.addItem(bookmarksItem)
        bookmarksItem.submenu = bookmarksMenu
        bookmarksMenu.delegate = self
        let addBookmark = item("Add Bookmark", action: #selector(addBookmarkFromMenu(_:)), key: "d", target: self)
        addBookmark.tag = MenuTag.bookmark
        bookmarksMenu.addItem(addBookmark)
        bookmarksMenu.addItem(item(
            "Show All Bookmarks",
            action: #selector(showAllBookmarks(_:)),
            key: "b",
            modifiers: [.command, .option],
            target: self
        ))
        let separator = NSMenuItem.separator()
        separator.tag = MenuTag.bookmarkSeparator
        bookmarksMenu.addItem(separator)

        let tabItem = NSMenuItem()
        main.addItem(tabItem)
        let tabMenu = NSMenu(title: "Tab")
        tabItem.submenu = tabMenu
        tabMenu.addItem(item(
            "Search Tabs…",
            action: #selector(searchTabs(_:)),
            key: "a",
            modifiers: [.command, .shift],
            target: self
        ))

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        windowItem.submenu = windowMenu
        windowMenu.delegate = self
        windowMenu.addItem(item("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(item("Zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item(
            "Select Next Tab",
            action: #selector(selectNextTab(_:)),
            key: "\t",
            modifiers: [.control],
            target: self
        ))
        windowMenu.addItem(item(
            "Select Previous Tab",
            action: #selector(selectPreviousTab(_:)),
            key: "\t",
            modifiers: [.control, .shift],
            target: self
        ))
        windowMenu.addItem(item(
            "Next Tab",
            action: #selector(selectNextTab(_:)),
            key: "]",
            modifiers: [.command, .shift],
            target: self
        ))
        windowMenu.addItem(item(
            "Previous Tab",
            action: #selector(selectPreviousTab(_:)),
            key: "[",
            modifiers: [.command, .shift],
            target: self
        ))
        windowMenu.addItem(.separator())
        for number in 1...9 {
            let title = number == 9 ? "Select Last Tab" : "Select Tab \(number)"
            let entry = item(title, action: #selector(selectTabByNumber(_:)), key: String(number), target: self)
            entry.tag = 100 + number
            windowMenu.addItem(entry)
        }

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        let showTour = item("Show Tour", action: #selector(showGuidedTour(_:)), target: self)
        showTour.setAccessibilityIdentifier("wyvern.help.showTour")
        helpMenu.addItem(showTour)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    @objc private func showGuidedTour(_ sender: Any?) {
        let browser = keyBrowser ?? windows.last ?? makeWindow()
        browser.showWindow(nil)
        browser.window?.makeKeyAndOrderFront(nil)
        guard browser.presentGuidedTour() else { return }
        if settings.settings.tourSeen == false {
            settings.update { $0.tourSeen = true }
        }
    }

    /// The only Ctrl-Tab and Cmd-W monitor. It lives here, in `AppDelegate.installTabKeyMonitor`.
    /// Browser windows do not install a second one. Command-W and Shift-Command-W are handed to
    /// the main menu, so they run the File menu items (validation, nil-target responder chain)
    /// before a web view can claim the key equivalent.
    private func installTabKeyMonitor() {
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handleReservedKeys(event)
            }
        }
    }

    private func handleReservedKeys(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 13 is W (kVK_ANSI_W). Command-W closes the tab even when a web view or field editor is focused.
        if event.keyCode == 13, flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return nil
            }
            return event
        }
        // 45 is N (kVK_ANSI_N). After the last window closes the app stays running; Command-N opens one.
        if event.keyCode == 45, flags.contains(.command), !flags.contains(.option), !flags.contains(.shift), windows.isEmpty {
            newWindow(nil)
            return nil
        }
        // 50 is the grave/tilde key (kVK_ANSI_Grave). Control-` and Control-~ select the previous tab,
        // web or terminal, like Control-Shift-Tab.
        if event.keyCode == 50, flags.contains(.control), !flags.contains(.command), !flags.contains(.option),
           event.window?.windowController is BrowserWindowController {
            selectPreviousTab(nil)
            return nil
        }
        // 48 is the tab key (kVK_Tab). The Carbon key-code header is not imported.
        guard event.keyCode == 48, flags.contains(.control), !flags.contains(.command), !flags.contains(.option) else {
            return event
        }
        guard event.window?.windowController is BrowserWindowController else {
            return event
        }
        if flags.contains(.shift) {
            selectPreviousTab(nil)
        } else {
            selectNextTab(nil)
        }
        return nil
    }

    private func item(
        _ title: String,
        action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty {
            entry.keyEquivalentModifierMask = modifiers
        }
        entry.target = target
        return entry
    }

    /// View > Split View. Targets stay nil so the key window validates them.
    /// The only other Control-Command shortcut in this menu bar is Enter Full Screen (⌃⌘F).
    /// Control-Option-Command arrows move a focused DevTools tab. The View menu owns those keys.
    /// While a split is showing, the window gives ⌃⌘\ to Unsplit All and clears it on Split Right.
    private func appendSplitCommands(to menu: NSMenu) {
        menu.addItem(item(
            "Split Right",
            action: #selector(BrowserWindowController.splitRight(_:)),
            key: "\\",
            modifiers: [.command, .control]
        ))
        menu.addItem(item(
            "Split Below",
            action: #selector(BrowserWindowController.splitDown(_:)),
            key: "\\",
            modifiers: [.command, .control, .shift]
        ))
        menu.addItem(item(
            "Close Pane",
            action: #selector(BrowserWindowController.closePane(_:)),
            key: "w",
            modifiers: [.command, .control]
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "Unsplit All",
            action: #selector(BrowserWindowController.unsplit(_:))
        ))
        menu.addItem(item(
            "Equalize",
            action: #selector(BrowserWindowController.equalizePanes(_:)),
            key: "=",
            modifiers: [.command, .control]
        ))
        let layoutMenu = NSMenu(title: "Layout")
        let layoutItem = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        layoutItem.submenu = layoutMenu
        menu.addItem(layoutItem)
        for arrangement in TileArrangement.allCases {
            let entry = item(
                Self.layoutTitle(arrangement),
                action: #selector(BrowserWindowController.applyLayout(_:))
            )
            entry.representedObject = arrangement.rawValue
            layoutMenu.addItem(entry)
        }
        let focusMenu = NSMenu(title: "Move Focus")
        let focusItem = NSMenuItem(title: "Move Focus", action: nil, keyEquivalent: "")
        focusItem.submenu = focusMenu
        menu.addItem(focusItem)
        focusMenu.addItem(item(
            "Left",
            action: #selector(BrowserWindowController.focusPaneLeft(_:)),
            key: "\u{F702}",
            modifiers: [.command, .control]
        ))
        focusMenu.addItem(item(
            "Right",
            action: #selector(BrowserWindowController.focusPaneRight(_:)),
            key: "\u{F703}",
            modifiers: [.command, .control]
        ))
        focusMenu.addItem(item(
            "Up",
            action: #selector(BrowserWindowController.focusPaneUp(_:)),
            key: "\u{F700}",
            modifiers: [.command, .control]
        ))
        focusMenu.addItem(item(
            "Down",
            action: #selector(BrowserWindowController.focusPaneDown(_:)),
            key: "\u{F701}",
            modifiers: [.command, .control]
        ))
        menu.addItem(item(
            "Swap Left",
            action: #selector(BrowserWindowController.swapPaneLeft(_:)),
            key: "\u{F702}",
            modifiers: [.command, .control, .shift]
        ))
        menu.addItem(item(
            "Swap Right",
            action: #selector(BrowserWindowController.swapPaneRight(_:)),
            key: "\u{F703}",
            modifiers: [.command, .control, .shift]
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "Move DevTools Left",
            action: #selector(BrowserWindowController.moveDevToolsLeft(_:)),
            key: "\u{F702}",
            modifiers: [.command, .option, .control]
        ))
        menu.addItem(item(
            "Move DevTools Right",
            action: #selector(BrowserWindowController.moveDevToolsRight(_:)),
            key: "\u{F703}",
            modifiers: [.command, .option, .control]
        ))
        menu.addItem(item(
            "Move DevTools Above",
            action: #selector(BrowserWindowController.moveDevToolsAbove(_:)),
            key: "\u{F700}",
            modifiers: [.command, .option, .control]
        ))
        menu.addItem(item(
            "Move DevTools Below",
            action: #selector(BrowserWindowController.moveDevToolsBelow(_:)),
            key: "\u{F701}",
            modifiers: [.command, .option, .control]
        ))
    }

    private static func layoutTitle(_ arrangement: TileArrangement) -> String {
        switch arrangement {
        case .twoColumns: return "2 Columns"
        case .twoRows: return "2 Rows"
        case .threeColumns: return "3 Columns"
        case .grid: return "2×2 Grid"
        case .onePlusTwo: return "1 + 2"
        }
    }

    private func setEnabled(_ tag: Int, _ enabled: Bool, in menu: NSMenu) {
        guard let entry = menu.items.first(where: { $0.tag == tag }) else { return }
        entry.isEnabled = enabled
    }

    private func rebuildBookmarkItems() {
        if let separatorIndex = bookmarksMenu.items.firstIndex(where: { $0.tag == MenuTag.bookmarkSeparator }) {
            while bookmarksMenu.items.count > separatorIndex + 1 {
                bookmarksMenu.removeItem(at: bookmarksMenu.items.count - 1)
            }
        }
        if bookmarkStore.bookmarks.isEmpty {
            let empty = NSMenuItem(title: "No Bookmarks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            bookmarksMenu.addItem(empty)
        } else {
            for bookmark in bookmarkStore.bookmarks {
                let entry = NSMenuItem(title: bookmark.title, action: #selector(openBookmarkFromMenu(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = bookmark.id.uuidString
                entry.toolTip = bookmark.url
                bookmarksMenu.addItem(entry)
            }
        }
        bookmarksMenu.addItem(.separator())
        let header = NSMenuItem(title: "Terminal Bookmarks", action: nil, keyEquivalent: "")
        header.isEnabled = false
        bookmarksMenu.addItem(header)
        for entry in terminalBookmarkItems() {
            bookmarksMenu.addItem(entry)
        }
    }

    private func rebuildTerminalMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in terminalBookmarkItems() {
            menu.addItem(entry)
        }
    }

    /// Enabled bookmarks only. Each item is new, so it can live in one menu.
    private func terminalBookmarkItems() -> [NSMenuItem] {
        let enabled = terminalBookmarks.enabledBookmarks
        if enabled.isEmpty {
            let empty = NSMenuItem(title: "No Terminal Bookmarks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return [empty]
        }
        return enabled.map { bookmark in
            let entry = NSMenuItem(title: bookmark.name, action: #selector(openTerminalBookmarkFromMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = bookmark.id.uuidString
            entry.toolTip = bookmark.command
            return entry
        }
    }

    @objc private func openTerminalBookmarkFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        let browser = keyBrowser ?? makeWindow()
        browser.openTerminalBookmark(id: id)
    }

    /// Explicit launch URLs skip crash restore and the startup page. Otherwise a crash prompt wins.
    private func launchInitialWindows() {
        let explicitOpen = launchConfig.openTarget != nil || !pendingOpenURLs.isEmpty
        if explicitOpen {
            let controller = makeWindow()
            flushPendingOpenURLs()
            presentPostLaunchSheets(on: controller)
            return
        }
        switch SessionStartup.choice(
            offerCrashRestore: session.offerCrashRestore,
            startupPage: settings.settings.startupPage,
            startupURL: settings.settings.startupURL
        ) {
        case .offerCrashRestore:
            let controller = makeWindow(seed: .newTab)
            presentCrashRestore(on: controller)
        case .restoreLastSession:
            if !restorePreviousSession(), windows.isEmpty {
                _ = makeWindow(seed: .newTab)
            }
            presentPostLaunchSheets(on: keyBrowser ?? windows.last)
        case .customURL(let raw):
            let controller = makeWindow(seed: .empty)
            if let url = resolveLaunchURL(raw) {
                controller.open(url)
            } else {
                _ = controller.addTab()
            }
            presentPostLaunchSheets(on: controller)
        case .newTab:
            let controller = makeWindow(seed: .newTab)
            presentPostLaunchSheets(on: controller)
        }
    }

    private func presentPostLaunchSheets(on controller: BrowserWindowController?) {
        guard let controller else { return }
        if !launchConfig.skipEngineChooser && !settings.settings.didChooseSearchEngine {
            controller.presentEngineChooser()
        } else if launchConfig.showSetup || (!launchConfig.skipEngineChooser && !settings.settings.didOfferFirstImport) {
            DispatchQueue.main.async { [weak self] in
                self?.presentSetup()
            }
        }
    }

    private func presentCrashRestore(on controller: BrowserWindowController) {
        let prompt = SessionRestorePrompt()
        restorePrompt = prompt
        var chosenRestore = false
        prompt.onChoice = { [weak prompt, weak controller] restore in
            chosenRestore = restore
            guard let sheet = prompt?.window else { return }
            let host = controller?.window ?? sheet.sheetParent
            host?.endSheet(sheet)
        }
        guard let sheet = prompt.window, let host = controller.window else {
            presentPostLaunchSheets(on: controller)
            return
        }
        host.beginSheet(sheet) { [weak self, weak controller] _ in
            let restore = chosenRestore
            Task { @MainActor in
                guard let self else { return }
                self.restorePrompt = nil
                if restore {
                    _ = self.restorePreviousSession()
                }
                self.presentPostLaunchSheets(on: self.keyBrowser ?? self.windows.last ?? controller)
            }
        }
    }

    @objc private func restorePreviousSessionFromMenu(_ sender: Any?) {
        // From the menu, keep the windows that are open now and add the previous run's windows.
        _ = restorePreviousSession(replacingOpenWindows: false)
    }

    /// Reopens the frozen previous-run snapshot. Returns false when nothing from it could be opened.
    @discardableResult
    private func restorePreviousSession(replacingOpenWindows: Bool = true) -> Bool {
        guard let snapshot = session.previous, snapshot.hasRestorableTabs else { return false }
        suppressSessionSaves = true
        defer {
            suppressSessionSaves = false
            session.scheduleSave()
        }
        let existing = replacingOpenWindows ? windows : []
        for controller in existing {
            controller.closeWithoutPrompt()
        }
        var opened: [BrowserWindowController] = []
        for record in snapshot.windows.reversed() where !record.tabs.isEmpty {
            let controller = makeWindow(seed: .empty)
            if controller.restore(snapshot: record) {
                opened.append(controller)
            } else {
                controller.closeWithoutPrompt()
            }
        }
        guard !opened.isEmpty else {
            if windows.isEmpty {
                _ = makeWindow(seed: .newTab)
            }
            return false
        }
        opened.last?.window?.makeKeyAndOrderFront(nil)
        return true
    }

    @objc private func searchTabs(_ sender: Any?) {
        if tabSearch == nil {
            let panel = TabSearchPanelController()
            panel.candidates = { [weak self] in
                self?.tabSearchCandidates() ?? []
            }
            tabSearch = panel
        }
        tabSearch?.showPalette()
    }

    private func tabSearchCandidates() -> [TabSearchCandidate] {
        windows.flatMap { controller in
            controller.searchEntries().map { entry in
                TabSearchCandidate(entry: entry, focus: { [weak controller] in
                    _ = controller?.focusTab(id: entry.id)
                })
            }
        }
    }

    private func captureOpenSession() -> SessionSnapshot {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
        var seen: [ObjectIdentifier] = []
        var records: [SessionWindowSnapshot] = []
        for controller in ordered where windows.contains(where: { $0 === controller }) {
            let ident = ObjectIdentifier(controller)
            if seen.contains(ident) { continue }
            seen.append(ident)
            records.append(controller.captureSnapshot())
        }
        for controller in windows where !seen.contains(ObjectIdentifier(controller)) {
            records.append(controller.captureSnapshot())
        }
        return SessionSnapshot(windows: records)
    }

    private func wireDownloads() {
        let settings = self.settings
        DownloadManager.shared.behavior = {
            let current = settings.settings
            let directory: URL
            if AppLocations.isDownloadsDirectoryOverridden {
                directory = AppLocations.downloadsDirectory
            } else if !current.downloadsDirectoryPath.isEmpty {
                directory = URL(fileURLWithPath: current.downloadsDirectoryPath, isDirectory: true)
            } else {
                directory = AppLocations.downloadsDirectory
            }
            return DownloadBehavior(
                directory: directory,
                askEachTime: current.askWhereToSaveDownloads,
                openWhenFinished: current.openAfterDownload
            )
        }
    }

    private func observeSettings() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .wyvernSettingsDidChange,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyRuntimeSettings()
            }
        }
    }

    private func applyRuntimeSettings() {
        let current = settings.settings
        BrowserTab.hardwareAcceleration = current.hardwareAcceleration
        BrowserTab.defaultFontSize = current.defaultFontSize
        BrowserTab.defaultZoomPercent = current.defaultZoomPercent
        BrowserTab.developerToolsEnabled = current.developerToolsEnabled
        updateDevelopMenuVisibility()
        if current.cookiePolicy != appliedCookiePolicy {
            appliedCookiePolicy = current.cookiePolicy
            CookiePolicyController.shared.apply(current.cookiePolicy)
        }
    }
}
