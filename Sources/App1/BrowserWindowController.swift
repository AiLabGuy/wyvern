// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import App1Core
import Darwin
import ObjectiveC
import WebKit

@MainActor
final class RootContentView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        if BenchMarks.isEnabled, window?.isVisible == true {
            BenchMarks.emitOnce("window-visible")
        }
        onLayout?()
    }
}

/// Runs after `NSThemeFrame` lays out, which is when AppKit puts the stoplights back
/// on the system titlebar midline. Replacing `NSView.layout` would hit every view, so
/// this installs only when `NSThemeFrame` has its own `layout`.
///
/// `setFrame` on a button during that pass calls `layout` again. The re-entrant call
/// must not run the original implementation: that puts the buttons back, and the outer
/// pass then bails out because it is already placing them.
private enum ThemeFrameTrafficHook {
    fileprivate static var installed = false
    private static var placingButtons = false
    private static var retainedBlock: AnyObject?
    private static var originalLayout: (@convention(c) (AnyObject, Selector) -> Void)?

    fileprivate static var isPlacingButtons: Bool { placingButtons }

    fileprivate static func beginPlacingButtons() {
        placingButtons = true
    }

    fileprivate static func endPlacingButtons() {
        placingButtons = false
    }

    fileprivate static func install() {
        guard !installed else { return }
        guard let themeClass: AnyClass = NSClassFromString("NSThemeFrame") else { return }
        let selector = #selector(NSView.layout)
        guard let method = class_getInstanceMethod(themeClass, selector) else { return }
        // Inherited `layout` is `NSView`'s. Swizzling that would run for every view.
        if let superclass = class_getSuperclass(themeClass),
           let inherited = class_getInstanceMethod(superclass, selector),
           inherited == method {
            return
        }
        let current = method_getImplementation(method)
        originalLayout = unsafeBitCast(current, to: (@convention(c) (AnyObject, Selector) -> Void).self)
        let block: @convention(block) (AnyObject) -> Void = { object in
            if ThemeFrameTrafficHook.isPlacingButtons {
                return
            }
            ThemeFrameTrafficHook.originalLayout?(object, selector)
            guard let view = object as? NSView else { return }
            guard let controller = view.window?.windowController as? BrowserWindowController else { return }
            // Layout is always on the main thread. The controller is not isolated.
            MainActor.assumeIsolated {
                controller.positionTrafficLightContainers(endLayoutPass: true)
            }
        }
        // `imp_implementationWithBlock` wants an object. A block does not bridge as `Any`.
        let object = unsafeBitCast(block, to: AnyObject.self)
        retainedBlock = object
        method_setImplementation(method, imp_implementationWithBlock(object))
        installed = true
    }
}

@MainActor
final class WindowBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        _ = dirtyRect
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .toolbar
    }

    override func accessibilityChildren() -> [Any]? {
        subviews
    }

    override func accessibilityIdentifier() -> String {
        "app1.bar"
    }
}

/// Gradient behind the tab strip and the toolbar, with a top highlight and a bottom rule.
@MainActor
final class BarBackdrop: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    var showsProgress = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.fillBarGradient(in: bounds)
        Theme.highlight.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        if showsProgress, fraction > 0, fraction < 1 {
            Theme.accent.setFill()
            let width = bounds.width * CGFloat(min(max(fraction, 0), 1))
            NSRect(x: 0, y: 0, width: width, height: 2).fill()
        } else {
            Theme.barLine.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class ToolbarRow: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Terminal page fill, including the padding around the terminal view.
@MainActor
final class TerminalSurface: NSView {
    var onAppearanceChange: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        Theme.termBackground.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearanceChange?()
    }
}

@MainActor
final class DividerLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.line.setFill()
        bounds.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class AccessibilityBridgeView: NSView {
    var bridged: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityChildren() -> [Any]? {
        if let bridged { return [bridged] }
        return []
    }
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSPopoverDelegate, BrowserTabHost, @unchecked Sendable {
    private let bookmarks: BookmarkStore
    private let settings: SettingsStore
    private let mediaPermissions: MediaPermissionStore
    private let sitePermissions: SitePermissionStore
    private let terminalBookmarks: TerminalBookmarkStore
    private let terminalPicker = TerminalBookmarkPicker()
    private var session: [SessionTab] = []
    private var activeID: UUID?
    var onClose: (() -> Void)?
    /// Called before tabs are shut down, so a snapshot can still see this window.
    var onPrepareClose: (() -> Void)?
    var onSessionChange: (() -> Void)?
    var suppressSessionNotes = false
    var printsWindowIdentity = false
    var opensDownloadsFromHook = false

    private let bar = WindowBarView()
    private let frameBar = BarBackdrop()
    private let toolbar = ToolbarRow()
    private let tabRegion = TabRegionView()
    private let pageHost = PageBackdrop()
    private let webContainer = NSView()
    private let terminalHost = TerminalSurface()
    private let bookmarksPage: BookmarksPageView
    private let newTabPage: NewTabPageView
    private let sidebarButton = ToolButton()
    private let backButton = ToolButton()
    private let forwardButton = ToolButton()
    private let reloadButton = ToolButton()
    private let addressField = AddressBarField()
    private let downloadsButton = ToolButton()
    private let healthBadge = NetworkHealthBadge()
    private let healthService = NetworkHealthService()
    private var healthPopover = NSPopover()
    private var healthPanel: NetworkHealthPanelController?
    private let appearanceProbe = NSTextField(labelWithString: "")
    private let preferenceProbe = NSTextField(labelWithString: "")
    private let axBridge = AccessibilityBridgeView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private var backdropHeightConstraint: NSLayoutConstraint?
    private var bookmarkObserver: NSObjectProtocol?
    private var faviconObserver: NSObjectProtocol?
    private var downloadsObserver: NSObjectProtocol?
    private var engineChooser: EngineChooserController?
    private var mediaPrompt: MediaPermissionPromptController?
    private var mediaPromptTabID: UUID?
    private var importSheet: BookmarkImportSheetController?
    private let downloadsPopover = NSPopover()
    private let downloadsPopoverController = DownloadsPopoverController()
    private var downloadsWidth: NSLayoutConstraint?
    private var downloadsGap: NSLayoutConstraint?
    /// Pins the health badge to the address field when the downloads button is hidden.
    private var healthToAddressGap: NSLayoutConstraint?
    private var healthWidth: NSLayoutConstraint?
    private var settingsObserver: NSObjectProtocol?
    private var didEmitWindowID = false
    private var didEmitPopoverID = false
    private var positioningTrafficLights = false
    /// One deferred stoplight pass is enough until the next layout.
    private var trafficPlacementQueued = false
    private var closeConfirmed = false
    private var barHeightConstraint: NSLayoutConstraint?
    private var guidedTour: GuidedTourOverlay?

    init(
        bookmarks: BookmarkStore,
        settings: SettingsStore,
        mediaPermissions: MediaPermissionStore,
        sitePermissions: SitePermissionStore,
        terminalBookmarks: TerminalBookmarkStore
    ) {
        self.bookmarks = bookmarks
        self.settings = settings
        self.mediaPermissions = mediaPermissions
        self.sitePermissions = sitePermissions
        self.terminalBookmarks = terminalBookmarks
        bookmarksPage = BookmarksPageView(store: bookmarks)
        newTabPage = NewTabPageView(store: bookmarks)
        super.init(window: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 830),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 980, height: 640)
        window.contentMinSize = NSSize(width: 980, height: 640)
        window.title = AppInfo.displayName
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.backgroundColor = Theme.win
        window.isMovableByWindowBackground = false
        let root = RootContentView()
        root.wantsLayer = true
        root.layer?.cornerRadius = MonoMetrics.windowRadius
        root.layer?.masksToBounds = true
        root.onLayout = { [weak self] in
            // Content layout runs before the titlebar puts the stoplights back.
            // The deferred pass runs after that. When the theme-frame hook already
            // centered them, this pass measures a zero delta and does not move them.
            self?.scheduleTrafficLightPlacement()
            self?.bringGuidedTourToFront()
        }
        ThemeFrameTrafficHook.install()
        window.contentView = root
        window.center()
        self.window = window
        window.delegate = self
        shouldCascadeWindows = true
        buildViews()
        // Ctrl-Tab lives only in AppDelegate.installTabKeyMonitor.
        bookmarkObserver = NotificationCenter.default.addObserver(
            forName: .app1BookmarksDidChange,
            object: bookmarks,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncBars(progressOnly: false)
            }
        }
        faviconObserver = NotificationCenter.default.addObserver(
            forName: .app1FaviconsDidClear,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for item in self.session {
                    if case .web(let tab) = item {
                        tab.favicon = nil
                    }
                }
                self.syncBars(progressOnly: false)
            }
        }
        downloadsObserver = NotificationCenter.default.addObserver(
            forName: .app1DownloadsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                self.syncDownloadsButton()
                self.downloadsPopoverController.reload()
                if note.userInfo?["pulse"] as? Bool == true {
                    self.pulseDownloadsButton()
                }
                if note.userInfo?["reveal"] as? Bool == true, self.opensDownloadsFromHook {
                    self.showDownloadsPopover()
                }
            }
        }
        downloadsPopover.contentViewController = downloadsPopoverController
        downloadsPopover.behavior = .transient
        downloadsPopover.animates = false
        downloadsPopover.delegate = self
        healthPopover.delegate = self
        healthService.enabled = settings.settings.netHealthEnabled
        healthService.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.healthBadge.snapshot = snapshot
                self?.healthPanel?.apply(snapshot)
            }
        }
        healthBadge.target = self
        healthBadge.action = #selector(healthBadgeTapped)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .app1SettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyNetHealthSetting()
                if let current = self?.settings.settings {
                    BrowserTab.hardwareAcceleration = current.hardwareAcceleration
                    BrowserTab.defaultFontSize = current.defaultFontSize
                    BrowserTab.defaultZoomPercent = current.defaultZoomPercent
                }
                self?.applyWebPageMetrics()
                self?.refreshAppearanceProbe()
                self?.applyBarHeight(MonoMetrics.barHeight)
                self?.syncBars(progressOnly: false)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var canGoBack: Bool { activeTab?.canGoBack ?? false }
    var canGoForward: Bool { activeTab?.canGoForward ?? false }
    var isLoadingPage: Bool { activeTab?.surface == .web && activeTab?.isLoading == true }
    /// Visible tabs only. Hidden kinds stay in the session and are not numbered.
    var tabCount: Int { visibleSession().count }
    var canBookmarkCurrent: Bool { Self.allowsBookmark(activeTab?.displayedURL) }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if BenchMarks.isEnabled, window?.isVisible == true {
            BenchMarks.emitOnce("window-visible")
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        _ = notification
        BenchMarks.emitOnce("window-visible")
        updateHealthVisibility()
    }

    func windowDidResignKey(_ notification: Notification) {
        _ = notification
        // Keep the health monitor live in unfocused-but-visible windows;
        // only occlusion (hidden, minimized, fully covered) pauses it.
        updateHealthVisibility()
    }

    /// The health monitor runs whenever any part of the window is on screen,
    /// focused or not. It pauses only when the window is fully hidden, to save power.
    private func updateHealthVisibility() {
        let visible = window?.occlusionState.contains(.visible) == true
        healthService.visibilityChanged(visible: visible)
        healthBadge.pauseSweep(!visible)
    }

    @objc private func occlusionChanged() {
        updateHealthVisibility()
    }

    func applyContentSize(width: Int, height: Int) {
        window?.setContentSize(NSSize(width: width, height: height))
        window?.center()
    }

    func armWindowIdentityPrint() {
        guard printsWindowIdentity else { return }
        perform(#selector(emitWindowIDFallback), with: nil, afterDelay: 3)
    }

    /// `configuration` is non-nil for `window.open` / `target=_blank`. WebKit navigates that view.
    /// A plain new tab shows the native new-tab page.
    @discardableResult
    func addTab(
        configuration supplied: WKWebViewConfiguration? = nil,
        loadBlank: Bool = true,
        autoplayURL: URL? = nil
    ) -> BrowserTab {
        if supplied == nil && loadBlank {
            BenchMarks.emit("tab-new-begin")
        }
        let configuration = supplied ?? BrowserTab.makeConfiguration()
        if supplied == nil {
            applyAutoplay(to: configuration, url: autoplayURL)
        }
        let surface: TabSurface = (supplied == nil && loadBlank) ? .newTab : .web
        let tab = BrowserTab(configuration: configuration, host: self, surface: surface)
        session.append(.web(tab))
        activeID = tab.id
        embedActiveSurface()
        if loadBlank && supplied == nil {
            tab.show(.newTab)
            focusLocationField()
        }
        presentActiveTabForBench()
        BenchMarks.emit("tab-ready")
        syncBars(progressOnly: false)
        noteSessionChange()
        return tab
    }

    func closeActiveTab() {
        guard let id = activeID else { return }
        closeTab(id: id)
    }

    /// File > Close Tab (Command-W), reached through the responder chain (nil target).
    /// Closing the last tab closes the window; the app keeps running.
    @objc func closeTab(_ sender: Any?) {
        closeActiveTab()
    }

    func closeTab(id: UUID) {
        guard let index = session.firstIndex(where: { $0.id == id }) else { return }
        if case .terminal(let terminal) = session[index], terminal.isProcessRunning() {
            confirmCloseTerminal {
                self.removeSession(id: id)
            }
            return
        }
        removeSession(id: id)
    }

    /// Removes the tab without shutting it down. A web view keeps its history.
    /// A terminal process keeps running; drag-out does not start it again.
    @discardableResult
    func detachTab(at index: Int) -> SessionTab? {
        guard session.indices.contains(index) else { return nil }
        let item = session.remove(at: index)
        let wasActive = item.id == activeID
        switch item {
        case .web(let tab):
            tab.host = nil
            unembed(tab.webView)
        case .terminal(let tab):
            unembed(tab.view)
        }
        if session.isEmpty {
            activeID = nil
            tabRegion.update(items: [])
            return item
        }
        if wasActive {
            let next = min(index, session.count - 1)
            activateTab(id: session[next].id, switching: true)
        }
        syncBars(progressOnly: false)
        noteSessionChange()
        return item
    }

    /// Inserts a live tab from another window. Does not create a web view, load a URL, or start a process.
    func adopt(tab: SessionTab, at index: Int) {
        if let existing = indexOfTab(id: tab.id) {
            moveTab(from: existing, to: index)
            return
        }
        if case .web(let web) = tab {
            web.host = self
        }
        var insertAt = index
        if insertAt < 0 {
            insertAt = 0
        }
        if insertAt > session.count {
            insertAt = session.count
        }
        session.insert(tab, at: insertAt)
        activateTab(id: tab.id, switching: true)
        syncBars(progressOnly: false)
        noteSessionChange()
    }

    func indexOfTab(id: UUID) -> Int? {
        session.firstIndex { $0.id == id }
    }

    /// Strip drop indexes count visible tabs. With nothing hidden, that index is the session index.
    func sessionIndex(forVisibleDrop visibleIndex: Int) -> Int {
        let visible = visibleSession()
        if visible.isEmpty {
            return min(max(visibleIndex, 0), session.count)
        }
        if visibleIndex <= 0 {
            guard let first = visible.first, let index = session.firstIndex(where: { $0.id == first.id }) else {
                return 0
            }
            return index
        }
        if visibleIndex >= visible.count {
            return session.count
        }
        let marker = visible[visibleIndex]
        return session.firstIndex(where: { $0.id == marker.id }) ?? session.count
    }

    /// Reorder inside this window. The embedded view stays put when the moved tab is already showing.
    func moveTab(from: Int, to rawTarget: Int) {
        guard session.indices.contains(from) else { return }
        var target = rawTarget
        if target < 0 {
            target = 0
        }
        if target > session.count {
            target = session.count
        }
        let moving = session[from]
        if target == from || target == from + 1 {
            if activeID != moving.id {
                activateTab(id: moving.id, switching: true)
                syncBars(progressOnly: false)
            }
            noteSessionChange()
            return
        }
        session.remove(at: from)
        if target > from {
            target -= 1
        }
        if target > session.count {
            target = session.count
        }
        session.insert(moving, at: target)
        activeID = moving.id
        syncBars(progressOnly: false)
        noteSessionChange()
    }

    /// Closes on the next turn so a drag's mouse-up is not still inside this window.
    func closeIfEmpty() {
        guard session.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session.isEmpty else { return }
            self.closeConfirmed = true
            self.window?.close()
        }
    }

    /// Drop of a tab drag. A strip under the pointer wins. Otherwise a release more than
    /// `TabDrag.detachDistance` from this strip, or outside this window, detaches the tab.
    /// The only tab in a window moves that window instead of leaving an empty one.
    func finishTabDrag(tabID: UUID, screenPoint: NSPoint, cursorOffsetInTab: NSPoint) {
        guard let from = indexOfTab(id: tabID) else { return }
        if let (target, visibleIndex) = Self.stripTarget(at: screenPoint) {
            let destination = target.sessionIndex(forVisibleDrop: visibleIndex)
            if target === self {
                moveTab(from: from, to: destination)
            } else if let tab = detachTab(at: from) {
                target.adopt(tab: tab, at: destination)
                closeIfEmpty()
            }
            return
        }
        let outside = window?.frame.contains(screenPoint) != true
        let vertical = tabRegion.verticalDistance(toScreenPoint: screenPoint)
        if outside || vertical > TabDrag.detachDistance {
            // Hidden tabs still belong to this window. Only a truly lone tab moves it.
            if session.count == 1 {
                placeTabUnderCursor(
                    tabID: tabID,
                    dropScreenPoint: screenPoint,
                    cursorOffsetInTab: cursorOffsetInTab
                )
            } else if let tab = detachTab(at: from) {
                openWindow(adopting: tab, dropScreenPoint: screenPoint, cursorOffsetInTab: cursorOffsetInTab)
            }
            return
        }
        moveTab(from: from, to: sessionIndex(forVisibleDrop: tabRegion.dropIndex(atScreenPoint: screenPoint)))
    }

    func tabStripDropIndex(atScreenPoint screenPoint: NSPoint) -> Int? {
        guard tabRegion.containsScreenPoint(screenPoint) else { return nil }
        return tabRegion.dropIndex(atScreenPoint: screenPoint)
    }

    /// Moves this window so the grabbed point of `tabID` sits on `dropScreenPoint`.
    func placeTabUnderCursor(tabID: UUID, dropScreenPoint: NSPoint, cursorOffsetInTab: NSPoint) {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        tabRegion.layoutSubtreeIfNeeded()
        let anchor = tabAnchorOnScreen(tabID: tabID, cursorOffsetInTab: cursorOffsetInTab, window: window)
        let dx = dropScreenPoint.x - anchor.x
        let dy = dropScreenPoint.y - anchor.y
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + dx, y: window.frame.origin.y + dy))
    }

    private func tabAnchorOnScreen(tabID: UUID, cursorOffsetInTab: NSPoint, window: NSWindow) -> NSPoint {
        if let view = tabRegion.itemView(id: tabID), view.bounds.width > 1, view.window != nil {
            let inWindow = view.convert(cursorOffsetInTab, to: nil)
            return window.convertToScreen(NSRect(origin: inWindow, size: .zero)).origin
        }
        let height = window.contentView?.bounds.height ?? window.frame.height
        let inWindow = NSPoint(
            x: MonoMetrics.contentLeading + cursorOffsetInTab.x,
            y: height - MonoMetrics.barHeight + cursorOffsetInTab.y
        )
        return window.convertToScreen(NSRect(origin: inWindow, size: .zero)).origin
    }

    private func openWindow(adopting tab: SessionTab, dropScreenPoint: NSPoint, cursorOffsetInTab: NSPoint) {
        MainActor.assumeIsolated {
            guard let delegate = NSApp.delegate as? AppDelegate else { return }
            delegate.presentDetachedTab(
                tab,
                dropScreenPoint: dropScreenPoint,
                cursorOffsetInTab: cursorOffsetInTab
            )
        }
    }

    /// Front-to-back. A browser whose frame contains the point but whose strip does not
    /// hides strips behind it. Non-browser windows and the drag image are not strips.
    private static func stripTarget(at screenPoint: NSPoint) -> (BrowserWindowController, Int)? {
        for window in NSApp.windows {
            guard window.isVisible, window.level == .normal else { continue }
            guard window.frame.contains(screenPoint) else { continue }
            guard let controller = window.windowController as? BrowserWindowController else {
                return nil
            }
            guard let index = controller.tabStripDropIndex(atScreenPoint: screenPoint) else {
                return nil
            }
            return (controller, index)
        }
        return nil
    }

    private func unembed(_ view: NSView) {
        guard let host = view.superview else { return }
        let attached = host.constraints.filter { constraint in
            let first = constraint.firstItem as? NSView
            let second = constraint.secondItem as? NSView
            return first === view || second === view
        }
        NSLayoutConstraint.deactivate(attached)
        view.removeFromSuperview()
    }

    /// Cmd-1…8 and Cmd-9 use the visible strip, web and terminal together.
    func selectTab(number: Int) {
        let visible = visibleSession()
        guard !visible.isEmpty else { return }
        let index = number == 9 ? visible.count - 1 : number - 1
        guard visible.indices.contains(index) else { return }
        activateTab(id: visible[index].id, switching: true)
        syncBars(progressOnly: false)
    }

    func selectRelativeTab(offset: Int) {
        let visible = visibleSession()
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex(where: { $0.id == activeID }) ?? 0
        let count = visible.count
        let next = (current + offset % count + count) % count
        activateTab(id: visible[next].id, switching: true)
        syncBars(progressOnly: false)
    }

    /// Enabled bookmarks only. A new or changed command asks before the process starts.
    func openTerminalBookmark(id: UUID) {
        guard let bookmark = terminalBookmarks.bookmark(id: id), bookmark.enabled else { return }
        let openInNewTab = settings.settings.terminalOpenInNewTab && bookmark.openInNewTab
        if !openInNewTab, let current = activeTerminalTab {
            session.removeAll { $0.id == current.id }
            current.shutdown()
        }
        let shell = TerminalLaunch.resolvedShell(
            bookmarkShell: bookmark.shell,
            defaultShell: settings.settings.terminalShell
        )
        let directory = TerminalLaunch.expandedDirectory(bookmark.workingDirectory)
        let tab = TerminalTab(
            bookmarkID: bookmark.id,
            name: bookmark.name,
            command: bookmark.command,
            shell: shell,
            workingDirectory: directory,
            fieldCaption: TerminalLaunch.fieldCaption(shell: shell, directory: bookmark.workingDirectory)
        )
        tab.fontSize = CGFloat(settings.settings.terminalFontSize)
        tab.attach()
        session.append(.terminal(tab))
        activeID = tab.id
        embedActiveSurface()
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalHost.layoutSubtreeIfNeeded()
        syncBars(progressOnly: false)
        noteSessionChange()
        if bookmark.canLaunch {
            tab.start()
        } else {
            confirmRun(tab)
        }
    }

    private func toggleTerminalPicker(anchor: NSView) {
        if terminalPicker.isShown {
            terminalPicker.dismiss()
            return
        }
        guard let host = window?.contentView else { return }
        terminalPicker.present(
            in: host,
            anchor: anchor,
            bookmarks: terminalBookmarks.enabledBookmarks
        ) { [weak self] id in
            self?.openTerminalBookmark(id: id)
        }
    }

    /// Ask leaves `mediaTypesRequiringUserActionForPlayback` untouched.
    /// Only a web view created for this URL can take Allow or Block.
    private func applyAutoplay(to configuration: WKWebViewConfiguration, url: URL?) {
        guard let url, let key = SitePermissionPolicy.originKey(for: url) else { return }
        let choice = sitePermissions.choice(origin: key, kind: .autoplay)
        BrowserTab.applyPlaybackOverride(SitePermissionPolicy.playbackOverride(choice), to: configuration)
    }

    func goBack() {
        guard activeTab?.surface == .web else { return }
        activeTab?.webView.goBack()
    }

    func goForward() {
        guard activeTab?.surface == .web else { return }
        activeTab?.webView.goForward()
    }

    func reloadPage() {
        guard activeTab?.surface == .web else { return }
        activeTab?.webView.reload()
    }

    func stopLoading() {
        guard activeTab?.surface == .web else { return }
        activeTab?.webView.stopLoading()
    }

    func reloadOrStop() {
        guard let tab = activeTab, tab.surface == .web else { return }
        if tab.isLoading {
            tab.webView.stopLoading()
        } else {
            tab.webView.reload()
        }
    }

    func focusLocationField() {
        guard let window else { return }
        if activeTab?.surface == .newTab {
            window.makeFirstResponder(newTabPage.inputField)
            return
        }
        window.makeFirstResponder(addressField.textField)
        addressField.textField.selectText(nil)
    }

    func showBookmarks() {
        if activeTab == nil {
            _ = addTab(loadBlank: false)
        }
        activeTab?.show(.bookmarks)
    }

    func toggleBookmark() {
        guard let tab = activeTab, let url = tab.displayedURL, Self.allowsBookmark(url) else { return }
        let raw = url.absoluteString
        if let existing = bookmarks.bookmark(matchingURL: raw) {
            bookmarks.remove(id: existing.id)
        } else {
            addBookmark()
        }
    }

    /// Address-bar shortcut adds the current page. It does not remove an existing bookmark.
    func addBookmark() {
        guard let tab = activeTab, let url = tab.displayedURL, Self.allowsBookmark(url) else { return }
        let raw = url.absoluteString
        let title = tab.title == "New Tab" || tab.title == "Bookmarks" ? raw : tab.title
        bookmarks.add(title: title, url: raw)
    }

    func loadInActiveTab(url: URL, userTypedFile: Bool) {
        let tab: BrowserTab
        if let activeTab {
            tab = activeTab
        } else {
            tab = addTab(loadBlank: false, autoplayURL: url)
        }
        tab.load(url: url, userTypedFile: userTypedFile)
    }

    func open(_ url: URL) {
        if activeTab == nil {
            _ = addTab(loadBlank: false, autoplayURL: url)
        }
        loadInActiveTab(url: url, userTypedFile: url.scheme?.lowercased() == "file")
        if activeTab?.surface == .newTab {
            focusLocationField()
        }
    }

    /// New tab in this window. Reuses a lone unused new-tab page so a cold launch with URLs
    /// does not leave an extra blank startup tab.
    func openInNewTab(_ url: URL) {
        // A reused new-tab web view already exists, so its autoplay setting cannot change.
        let reuseBlank = session.isEmpty || (session.count == 1 && activeTab?.surface == .newTab)
        if !reuseBlank {
            _ = addTab(loadBlank: false, autoplayURL: url)
        }
        open(url)
    }

    func presentEngineChooser() {
        let chooser = EngineChooserController(store: settings)
        engineChooser = chooser
        guard let sheet = chooser.window, let host = window else { return }
        host.beginSheet(sheet) { [weak self] _ in
            Task { @MainActor in
                self?.engineChooser = nil
                self?.syncBars(progressOnly: false)
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        terminalPicker.dismiss()
        positionTrafficLightContainers(endLayoutPass: true)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        positionTrafficLightContainers(endLayoutPass: true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        positionTrafficLightContainers(endLayoutPass: true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        positionTrafficLightContainers(endLayoutPass: true)
    }

    func closeWithoutPrompt() {
        closeConfirmed = true
        window?.close()
    }

    func captureSnapshot() -> SessionWindowSnapshot {
        let tabs = session.map { item -> SessionTabSnapshot in
            switch item {
            case .web(let tab):
                return SessionTabSnapshot(kind: .web, url: tab.displayedURL?.absoluteString, terminalBookmarkID: nil)
            case .terminal(let tab):
                return SessionTabSnapshot(kind: .terminal, url: nil, terminalBookmarkID: tab.bookmarkID)
            }
        }
        let selected = session.firstIndex(where: { $0.id == activeID }) ?? 0
        return SessionWindowSnapshot(tabs: tabs, selectedIndex: selected)
    }

    func searchEntries() -> [TabSearchEntry] {
        session.map { item in
            switch item {
            case .web(let tab):
                return TabSearchEntry(
                    id: tab.id,
                    title: tab.title,
                    url: tab.displayedURL?.absoluteString ?? "",
                    kind: .web
                )
            case .terminal(let tab):
                return TabSearchEntry(id: tab.id, title: tab.name, url: tab.command, kind: .terminal)
            }
        }
    }

    @discardableResult
    func focusTab(id: UUID) -> Bool {
        guard session.contains(where: { $0.id == id }) else { return false }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        activateTab(id: id, switching: true)
        syncBars(progressOnly: false)
        return true
    }

    /// Replaces this window's tabs with a saved window. Returns false when nothing could be opened.
    @discardableResult
    func restore(snapshot: SessionWindowSnapshot) -> Bool {
        let wasSuppressed = suppressSessionNotes
        suppressSessionNotes = true
        defer { suppressSessionNotes = wasSuppressed }
        for item in session {
            switch item {
            case .web(let tab):
                tab.shutdown()
            case .terminal(let tab):
                tab.shutdown()
            }
        }
        session.removeAll()
        activeID = nil
        var created: [(index: Int, id: UUID)] = []
        for (index, record) in snapshot.tabs.enumerated() {
            let before = session.count
            appendRestored(record)
            if session.count > before, let id = session.last?.id {
                created.append((index, id))
            }
        }
        guard !session.isEmpty else { return false }
        let chosen = created.last(where: { $0.index <= snapshot.selectedIndex })?.id ?? session[0].id
        activateTab(id: chosen, switching: true)
        syncBars(progressOnly: false)
        return true
    }

    func applyWebPageMetrics() {
        let font = settings.settings.defaultFontSize
        let zoom = settings.settings.defaultZoomPercent
        for item in session {
            if case .web(let tab) = item {
                tab.applyPageMetrics(fontSize: font, zoomPercent: zoom)
            }
        }
    }

    private func appendRestored(_ record: SessionTabSnapshot) {
        switch record.kind {
        case .web:
            let tab = addTab(loadBlank: false)
            let raw = record.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty, let url = URL(string: raw) else {
                tab.show(.newTab)
                return
            }
            tab.load(url: url, userTypedFile: url.scheme?.lowercased() == "file")
        case .terminal:
            guard let id = record.terminalBookmarkID else { return }
            appendTerminalBookmark(id: id)
        }
    }

    private func appendTerminalBookmark(id: UUID) {
        guard let bookmark = terminalBookmarks.bookmark(id: id), bookmark.enabled else { return }
        let shell = TerminalLaunch.resolvedShell(
            bookmarkShell: bookmark.shell,
            defaultShell: settings.settings.terminalShell
        )
        let directory = TerminalLaunch.expandedDirectory(bookmark.workingDirectory)
        let tab = TerminalTab(
            bookmarkID: bookmark.id,
            name: bookmark.name,
            command: bookmark.command,
            shell: shell,
            workingDirectory: directory,
            fieldCaption: TerminalLaunch.fieldCaption(shell: shell, directory: bookmark.workingDirectory)
        )
        tab.fontSize = CGFloat(settings.settings.terminalFontSize)
        tab.attach()
        session.append(.terminal(tab))
        activeID = tab.id
        embedActiveSurface()
        if bookmark.canLaunch {
            tab.start()
        } else {
            confirmRun(tab)
        }
    }

    private func noteSessionChange() {
        guard !suppressSessionNotes else { return }
        onSessionChange?()
    }

    /// A live terminal process asks before the window goes away. The flag avoids a second prompt.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed || !anyTerminalRunning() {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Close this window?"
        alert.informativeText = "A terminal process is still running. Closing stops it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.closeConfirmed = true
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onPrepareClose?()
        guidedTour?.end()
        guidedTour = nil
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        if let bookmarkObserver {
            NotificationCenter.default.removeObserver(bookmarkObserver)
            self.bookmarkObserver = nil
        }
        if let faviconObserver {
            NotificationCenter.default.removeObserver(faviconObserver)
            self.faviconObserver = nil
        }
        if let downloadsObserver {
            NotificationCenter.default.removeObserver(downloadsObserver)
            self.downloadsObserver = nil
        }
        downloadsPopover.performClose(nil)
        terminalPicker.dismiss()
        dismissMediaPrompt(grant: false)
        if let sheet = importSheet?.window {
            window?.endSheet(sheet)
        }
        for item in session {
            switch item {
            case .web(let tab):
                tab.shutdown()
            case .terminal(let tab):
                tab.shutdown()
            }
        }
        session.removeAll()
        onClose?()
    }

    func browserTabDidUpdate(_ tab: BrowserTab, progressOnly: Bool) {
        guard tab.id == activeTab?.id || !progressOnly else { return }
        if tab.id == activeTab?.id || session.contains(where: { $0.id == tab.id }) {
            syncBars(progressOnly: progressOnly && tab.id == activeTab?.id)
        }
        if !progressOnly {
            noteSessionChange()
        }
    }

    func browserTabDidSettle(_ tab: BrowserTab) {
        guard tab.id == activeTab?.id else { return }
        emitWindowID()
        noteSessionChange()
    }

    func browserTab(_ tab: BrowserTab, createWebViewWith configuration: WKWebViewConfiguration) -> WKWebView? {
        let created = addTab(configuration: configuration, loadBlank: false)
        return created.webView
    }

    func browserTabDidRequestClose(_ tab: BrowserTab) {
        closeTab(id: tab.id)
    }

    func browserTab(_ tab: BrowserTab, confirmExternal url: URL) {
        let alert = NSAlert()
        alert.messageText = "Open this link outside \(AppInfo.displayName)?"
        alert.informativeText = url.absoluteString
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(url)
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    func browserTabDeniedFile(_ tab: BrowserTab) {
        let alert = NSAlert()
        alert.messageText = "Local file blocked"
        alert.informativeText = "Local files open only when you type them in the address field."
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    func browserTab(
        _ tab: BrowserTab,
        decideMediaCapture originKey: String,
        kind: MediaCaptureKind,
        completion: @escaping (Bool) -> Void
    ) {
        // A nil device choice is Ask and still prompts. A stored `both` choice is unchanged.
        let stored = MediaPermissionPolicy.effectiveStoredDecision(
            requested: kind,
            camera: mediaPermissions.decision(origin: originKey, kind: .camera),
            microphone: mediaPermissions.decision(origin: originKey, kind: .microphone),
            both: mediaPermissions.decision(origin: originKey, kind: .both)
        )
        switch MediaPermissionPolicy.evaluate(originKey: originKey, kind: kind, stored: stored) {
        case .grant:
            completion(true)
        case .deny:
            completion(false)
        case .prompt:
            presentMediaPrompt(tab: tab, origin: originKey, kind: kind, completion: completion)
        }
    }

    func browserTab(_ tab: BrowserTab, permissionChoice originKey: String, kind: SitePermissionKind) -> SitePermissionChoice {
        _ = tab
        return sitePermissions.choice(origin: originKey, kind: kind)
    }

    func browserTabDidCancelMediaPrompt(_ tab: BrowserTab) {
        guard mediaPromptTabID == tab.id else { return }
        mediaPrompt?.onChoice = nil
        if let sheet = mediaPrompt?.window {
            window?.endSheet(sheet)
        }
        mediaPrompt = nil
        mediaPromptTabID = nil
    }

    func browserTab(_ tab: BrowserTab, hostDidChange host: String?) {
        guard tab.id == activeID else { return }
        feedHealth(host: host, url: tab.displayedURL)
    }

    func presentBookmarkImport() {
        if let existing = importSheet, let sheet = existing.window, sheet.sheetParent != nil {
            return
        }
        let sheetController = BookmarkImportSheetController(store: bookmarks)
        importSheet = sheetController
        guard let sheet = sheetController.window, let host = window else { return }
        host.beginSheet(sheet) { [weak self] _ in
            Task { @MainActor in
                self?.importSheet = nil
                self?.bookmarksPage.reload()
            }
        }
    }

    /// The active web tab. Nil while a terminal tab is selected.
    /// A nil selection still falls back to the first web tab, matching the previous window.
    private var activeTab: BrowserTab? {
        if let activeID {
            for item in session {
                if case .web(let tab) = item, tab.id == activeID {
                    return tab
                }
            }
            return nil
        }
        for item in session {
            if case .web(let tab) = item {
                return tab
            }
        }
        return nil
    }

    private var activeTerminalTab: TerminalTab? {
        guard let activeID else { return nil }
        for item in session {
            if case .terminal(let tab) = item, tab.id == activeID {
                return tab
            }
        }
        return nil
    }

    private func visibleSession() -> [SessionTab] {
        let visibility = settings.settings.tabVisibility
        return session.filter { visibility.allows($0.kind) }
    }

    private func ensureVisibleSelection() {
        let visible = visibleSession()
        if let activeID, visible.contains(where: { $0.id == activeID }) {
            return
        }
        if let first = visible.first {
            activateTab(id: first.id, switching: false)
        }
    }

    private func anyTerminalRunning() -> Bool {
        for item in session {
            if case .terminal(let tab) = item, tab.isProcessRunning() {
                return true
            }
        }
        return false
    }

    private func buildViews() {
        guard let content = window?.contentView else { return }
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.setAccessibilityIdentifier("app1.bar")
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.onAppearanceChange = { [weak self] in
            self?.activeTerminalTab?.applyColors()
        }
        bookmarksPage.translatesAutoresizingMaskIntoConstraints = false
        newTabPage.translatesAutoresizingMaskIntoConstraints = false
        tabRegion.translatesAutoresizingMaskIntoConstraints = false
        frameBar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        configureTool(sidebarButton, glyph: .sidebar, label: "Bookmarks", action: #selector(sidebarTapped))
        configureTool(backButton, glyph: .back, label: "Back", action: #selector(backTapped))
        backButton.setAccessibilityIdentifier("app1.back")
        configureTool(forwardButton, glyph: .forward, label: "Forward", action: #selector(forwardTapped))
        configureTool(reloadButton, glyph: .reload, label: "Reload", action: #selector(reloadTapped))

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.onSubmit = { [weak self] text in self?.commit(text: text) }
        addressField.onToggleStar = { [weak self] in self?.toggleBookmark() }

        tabRegion.onSelect = { [weak self] id in
            self?.activateTab(id: id, switching: true)
            self?.syncBars(progressOnly: false)
        }
        tabRegion.onClose = { [weak self] id in
            self?.closeTab(id: id)
        }
        tabRegion.onNewTab = { [weak self] in
            _ = self?.addTab()
        }
        tabRegion.onTerminalPicker = { [weak self] anchor in
            self?.toggleTerminalPicker(anchor: anchor)
        }
        bookmarksPage.onOpen = { [weak self] bookmark in
            self?.openBookmark(bookmark)
        }
        bookmarksPage.onImport = { [weak self] in
            self?.presentBookmarkImport()
        }
        newTabPage.onSubmit = { [weak self] text in
            self?.commit(text: text)
        }
        newTabPage.onOpen = { [weak self] bookmark in
            self?.openBookmark(bookmark)
        }

        content.addSubview(frameBar)
        content.addSubview(pageHost)
        frameBar.addSubview(bar)
        frameBar.addSubview(toolbar)
        toolbar.addSubview(sidebarButton)
        toolbar.addSubview(backButton)
        toolbar.addSubview(forwardButton)
        toolbar.addSubview(reloadButton)
        toolbar.addSubview(addressField)
        bar.addSubview(tabRegion)
        toolbar.addSubview(downloadsButton)
        toolbar.addSubview(healthBadge)
        bar.addSubview(appearanceProbe)
        axBridge.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(axBridge)
        pageHost.addSubview(webContainer)
        pageHost.addSubview(terminalHost)
        pageHost.addSubview(bookmarksPage)
        pageHost.addSubview(newTabPage)

        healthBadge.translatesAutoresizingMaskIntoConstraints = false
        appearanceProbe.isHidden = false
        appearanceProbe.alphaValue = 0.01
        appearanceProbe.isBezeled = false
        appearanceProbe.drawsBackground = false
        appearanceProbe.isEditable = false
        appearanceProbe.isSelectable = false
        appearanceProbe.translatesAutoresizingMaskIntoConstraints = false
        appearanceProbe.setAccessibilityIdentifier("app1.appearance")
        appearanceProbe.setAccessibilityElement(true)
        appearanceProbe.setAccessibilityRole(.staticText)
        preferenceProbe.isHidden = false
        preferenceProbe.alphaValue = 0.01
        preferenceProbe.isBezeled = false
        preferenceProbe.drawsBackground = false
        preferenceProbe.isEditable = false
        preferenceProbe.isSelectable = false
        preferenceProbe.translatesAutoresizingMaskIntoConstraints = false
        preferenceProbe.setAccessibilityIdentifier("app1.appearance.preference")
        preferenceProbe.setAccessibilityElement(true)
        preferenceProbe.setAccessibilityRole(.staticText)
        bar.addSubview(preferenceProbe)
        refreshAppearanceProbe()
        healthBadge.setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        downloadsButton.glyph = .download
        downloadsButton.pointSize = MonoMetrics.navGlyph
        downloadsButton.tint = Theme.mute
        downloadsButton.toolTip = "Downloads"
        downloadsButton.setAccessibilityLabel("Downloads")
        downloadsButton.setAccessibilityIdentifier("app1.downloads.button")
        downloadsButton.target = self
        downloadsButton.action = #selector(downloadsTapped)
        downloadsButton.translatesAutoresizingMaskIntoConstraints = false
        downloadsButton.isHidden = true

        tabRegion.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabRegion.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            frameBar.topAnchor.constraint(equalTo: content.topAnchor),
            frameBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            frameBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            bar.topAnchor.constraint(equalTo: frameBar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: frameBar.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: frameBar.trailingAnchor),

            toolbar.leadingAnchor.constraint(equalTo: frameBar.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: frameBar.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: frameBar.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: MonoMetrics.toolbarHeight),

            pageHost.topAnchor.constraint(equalTo: frameBar.bottomAnchor),
            pageHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            sidebarButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: MonoMetrics.toolbarPadding),
            sidebarButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: MonoMetrics.control),
            sidebarButton.heightAnchor.constraint(equalToConstant: MonoMetrics.control),

            backButton.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: MonoMetrics.itemGap),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: MonoMetrics.control),
            backButton.heightAnchor.constraint(equalToConstant: MonoMetrics.control),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: MonoMetrics.itemGap),
            forwardButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: MonoMetrics.control),
            forwardButton.heightAnchor.constraint(equalToConstant: MonoMetrics.control),

            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: MonoMetrics.itemGap),
            reloadButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: MonoMetrics.control),
            reloadButton.heightAnchor.constraint(equalToConstant: MonoMetrics.control),

            addressField.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: MonoMetrics.itemGap),
            addressField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: MonoMetrics.urlHeight),

            tabRegion.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: MonoMetrics.contentLeading),
            tabRegion.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -MonoMetrics.barTrailing),
            tabRegion.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            tabRegion.heightAnchor.constraint(equalToConstant: MonoMetrics.tabHeight),

            downloadsButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            downloadsButton.heightAnchor.constraint(equalToConstant: MonoMetrics.control),
            downloadsButton.trailingAnchor.constraint(equalTo: healthBadge.leadingAnchor, constant: -MonoMetrics.itemGap),

            healthBadge.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            healthBadge.heightAnchor.constraint(equalToConstant: MonoMetrics.netHealthBadgeHeight),
            healthBadge.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -MonoMetrics.toolbarPadding),

            appearanceProbe.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            appearanceProbe.topAnchor.constraint(equalTo: bar.topAnchor),
            appearanceProbe.widthAnchor.constraint(equalToConstant: 8),
            appearanceProbe.heightAnchor.constraint(equalToConstant: 8),
            preferenceProbe.leadingAnchor.constraint(equalTo: appearanceProbe.trailingAnchor),
            preferenceProbe.topAnchor.constraint(equalTo: bar.topAnchor),
            preferenceProbe.widthAnchor.constraint(equalToConstant: 8),
            preferenceProbe.heightAnchor.constraint(equalToConstant: 8),
            axBridge.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            axBridge.topAnchor.constraint(equalTo: bar.topAnchor),
            axBridge.widthAnchor.constraint(equalToConstant: 1),
            axBridge.heightAnchor.constraint(equalToConstant: 1)
        ])
        let width = downloadsButton.widthAnchor.constraint(equalToConstant: 0)
        let gap = downloadsButton.leadingAnchor.constraint(equalTo: addressField.trailingAnchor, constant: MonoMetrics.itemGap)
        let fallback = healthBadge.leadingAnchor.constraint(equalTo: addressField.trailingAnchor, constant: MonoMetrics.itemGap)
        let healthW = healthBadge.widthAnchor.constraint(equalToConstant: 92)
        healthWidth = healthW
        healthW.isActive = true
        downloadsWidth = width
        downloadsGap = gap
        healthToAddressGap = fallback
        width.isActive = true
        gap.isActive = false
        fallback.isActive = true
        let barHeight = bar.heightAnchor.constraint(equalToConstant: MonoMetrics.barHeight)
        barHeightConstraint = barHeight
        barHeight.isActive = true
        let backdropHeight = frameBar.heightAnchor.constraint(equalToConstant: MonoMetrics.backdropHeight)
        backdropHeightConstraint = backdropHeight
        backdropHeight.isActive = true
        pinToEdges(webContainer)
        pinToEdges(terminalHost)
        pinToEdges(bookmarksPage)
        pinToEdges(newTabPage)
        bookmarksPage.isHidden = true
        newTabPage.isHidden = true
        terminalHost.isHidden = true
        syncDownloadsButton()
        applyNetHealthSetting()
        applyBarHeight(MonoMetrics.barHeight)
    }

    private func applyNetHealthSetting() {
        let on = settings.settings.netHealthEnabled
        healthService.enabled = on
        healthBadge.isHidden = !on
        healthBadge.setAccessibilityElement(on)
        healthWidth?.constant = on ? 92 : 0
        if !on {
            healthPopover.close()
            healthService.stop()
        } else {
            feedHealth(host: activeTab?.displayedURL?.host, url: activeTab?.displayedURL)
        }
        refreshAppearanceProbe()
        guidedTour?.refresh()
    }

    /// Coach marks over this window. Hidden anchors are omitted. Returns false when there is no content view.
    @discardableResult
    func presentGuidedTour() -> Bool {
        guard let content = window?.contentView else { return false }
        if let guidedTour {
            if content.subviews.last !== guidedTour {
                content.addSubview(guidedTour)
            }
            guidedTour.restart()
            return true
        }
        let overlay = GuidedTourOverlay(steps: tourSteps())
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onFinish = { [weak self] in
            self?.guidedTour = nil
        }
        content.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        guidedTour = overlay
        content.layoutSubtreeIfNeeded()
        overlay.start()
        return true
    }

    private func bringGuidedTourToFront() {
        guard let guidedTour, let content = window?.contentView else { return }
        if content.subviews.last !== guidedTour {
            content.addSubview(guidedTour)
        }
        guidedTour.refresh()
    }

    private func tourSteps() -> [GuidedTourStep] {
        [
            GuidedTourStep(
                id: "address",
                title: "Address bar",
                message: GuidedTourCopy.address,
                anchor: { [weak self] in self?.addressField }
            ),
            GuidedTourStep(
                id: "tabs",
                title: "Tabs",
                message: GuidedTourCopy.tabs,
                anchor: { [weak self] in self?.tabRegion }
            ),
            GuidedTourStep(
                id: "terminal",
                title: "Terminal",
                message: GuidedTourCopy.terminal,
                anchor: { [weak self] in self?.tabRegion.newTabButton }
            ),
            GuidedTourStep(
                id: "bookmarks",
                title: "Bookmarks",
                message: GuidedTourCopy.bookmarks,
                anchor: { [weak self] in self?.sidebarButton }
            ),
            GuidedTourStep(
                id: "network",
                title: "Network health",
                message: GuidedTourCopy.networkHealth(),
                anchor: { [weak self] in self?.healthBadge }
            ),
            GuidedTourStep(
                id: "settings",
                title: "Settings",
                message: GuidedTourCopy.settings(),
                anchor: { [weak self] in self?.window?.contentView },
                pointsAtTop: true
            )
        ]
    }

    private func refreshAppearanceProbe() {
        let name = AppearanceController.currentName()
        appearanceProbe.stringValue = name
        appearanceProbe.setAccessibilityValue(name)
        appearanceProbe.setAccessibilityTitle(name)
        appearanceProbe.setAccessibilityLabel("appearance")
        let preference = settings.settings.appearance.rawValue
        preferenceProbe.stringValue = preference
        preferenceProbe.setAccessibilityValue(preference)
        preferenceProbe.setAccessibilityLabel("appearance preference")
    }

    private func applyBarHeight(_ height: CGFloat) {
        barHeightConstraint?.constant = height
        backdropHeightConstraint?.constant = height + MonoMetrics.toolbarHeight
        positionTrafficLightContainers(endLayoutPass: false)
    }

    private func feedHealth(host: String?, url: URL?) {
        guard settings.settings.netHealthEnabled else {
            healthService.stop()
            return
        }
        let scheme = url?.scheme?.lowercased() ?? ""
        if let host, !host.isEmpty, scheme == "http" || scheme == "https" {
            healthService.start(host: host, scheme: scheme)
        } else {
            healthService.stop()
        }
    }

    @objc private func healthBadgeTapped() {
        toggleHealthPanel()
    }

    private func toggleHealthPanel() {
        if healthPopover.isShown {
            healthPopover.performClose(nil)
            return
        }
        let panel = NetworkHealthPanelController(service: healthService)
        healthPanel = panel
        healthPopover.contentViewController = panel
        healthPopover.behavior = .transient
        healthPopover.animates = false
        healthPopover.show(relativeTo: healthBadge.bounds, of: healthBadge, preferredEdge: .maxY)
        healthBadge.extraAccessibilityChild = panel.view
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if popover === healthPopover {
            healthBadge.extraAccessibilityChild = nil
        }
        if popover === downloadsPopover {
            downloadsButton.extraAccessibilityChild = nil
        }
    }

    private func pinToEdges(_ view: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: pageHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor)
        ])
    }

    private func configureTool(_ button: ToolButton, glyph: IconGlyph, label: String, action: Selector) {
        button.glyph = glyph
        button.pointSize = MonoMetrics.navGlyph
        button.tint = Theme.mute
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func activateTab(id: UUID, switching: Bool) {
        if switching {
            BenchMarks.emit("tab-switch-begin")
        }
        activeID = id
        embedActiveSurface()
        presentActiveTabForBench()
        if switching {
            BenchMarks.emit("tab-switch-completed")
        }
        if let tab = activeTab {
            feedHealth(host: tab.displayedURL?.host, url: tab.displayedURL)
        } else {
            feedHealth(host: nil, url: nil)
        }
        updateHealthVisibility()
        noteSessionChange()
    }

    private func presentActiveTabForBench() {
        guard BenchMarks.isEnabled else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        if let webView = activeTab?.webView {
            webView.layoutSubtreeIfNeeded()
            webView.displayIfNeeded()
        }
        webContainer.layoutSubtreeIfNeeded()
        webContainer.displayIfNeeded()
        window?.displayIfNeeded()
    }

    private func embedActiveSurface() {
        if activeTerminalTab != nil {
            for subview in webContainer.subviews {
                subview.removeFromSuperview()
            }
            if let view = activeTerminalTab?.view {
                embed(view, in: terminalHost, insets: NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22))
            }
            return
        }
        for subview in terminalHost.subviews {
            subview.removeFromSuperview()
        }
        embedActiveWebView()
    }

    private func embed(_ view: NSView, in host: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        if view.superview === host { return }
        for subview in host.subviews {
            subview.removeFromSuperview()
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -insets.bottom)
        ])
    }

    private func embedActiveWebView() {
        guard let webView = activeTab?.webView else { return }
        webView.underPageBackgroundColor = Theme.page
        if webView.superview === webContainer { return }
        for subview in webContainer.subviews {
            subview.removeFromSuperview()
        }
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
    }

    private func syncBars(progressOnly: Bool) {
        ensureVisibleSelection()
        if let terminal = activeTerminalTab {
            syncTerminalBars(terminal)
            return
        }
        guard let tab = activeTab else { return }
        let loading = tab.surface == .web && tab.isLoading && tab.estimatedProgress < 1
        frameBar.showsProgress = loading
        frameBar.fraction = loading ? tab.estimatedProgress : 0
        if progressOnly {
            return
        }
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        reloadButton.isEnabled = true
        backButton.toolTip = "Back"
        forwardButton.toolTip = "Forward"
        reloadButton.toolTip = loading ? "Stop" : "Reload"
        reloadButton.setAccessibilityLabel(loading ? "Stop" : "Reload")
        let allowed = Self.allowsBookmark(tab.displayedURL)
        let bookmarked = allowed && tab.displayedURL.flatMap { bookmarks.bookmark(matchingURL: $0.absoluteString) } != nil
        addressField.present(url: tab.displayedURL, bookmarked: bookmarked, canBookmark: allowed)
        window?.title = "\(tab.title) — \(AppInfo.displayName)"
        feedHealth(host: tab.displayedURL?.host, url: tab.displayedURL)
        refreshAppearanceProbe()
        tabRegion.update(items: stripItems(selectedID: tab.id))
        terminalHost.isHidden = true
        webContainer.isHidden = tab.surface != .web
        bookmarksPage.isHidden = tab.surface != .bookmarks
        newTabPage.isHidden = tab.surface != .newTab
        if tab.surface == .bookmarks {
            bookmarksPage.reload()
        }
        if tab.surface == .newTab {
            newTabPage.reload()
        }
    }

    private func syncTerminalBars(_ terminal: TerminalTab) {
        frameBar.showsProgress = false
        frameBar.fraction = 0
        backButton.isEnabled = false
        forwardButton.isEnabled = false
        reloadButton.isEnabled = false
        reloadButton.toolTip = "Reload"
        reloadButton.setAccessibilityLabel("Reload")
        terminal.fontSize = CGFloat(settings.settings.terminalFontSize)
        terminal.applyColors()
        addressField.presentCommand(terminal.command, caption: terminal.fieldCaption)
        window?.title = "\(terminal.name) — \(AppInfo.displayName)"
        feedHealth(host: nil, url: nil)
        refreshAppearanceProbe()
        tabRegion.update(items: stripItems(selectedID: terminal.id))
        terminalHost.isHidden = false
        terminalHost.needsDisplay = true
        webContainer.isHidden = true
        bookmarksPage.isHidden = true
        newTabPage.isHidden = true
    }

    private func stripItems(selectedID: UUID) -> [TabStripItem] {
        visibleSession().map { item in
            switch item {
            case .web(let tab):
                return tabItem(for: tab, selected: tab.id == selectedID)
            case .terminal(let tab):
                return TabStripItem(
                    id: tab.id,
                    title: tab.command,
                    badgeLetter: "",
                    badgeHex: "",
                    favicon: nil,
                    selected: tab.id == selectedID,
                    kind: .terminal,
                    glyph: .terminal,
                    accessibilityLabel: "Terminal tab",
                    accessibilityValue: tab.command,
                    accessibilityHelp: tab.name + "\n" + tab.command
                )
            }
        }
    }

    private func removeSession(id: UUID) {
        guard let index = session.firstIndex(where: { $0.id == id }) else { return }
        if case .web = session[index], mediaPromptTabID == id {
            dismissMediaPrompt(grant: false)
        }
        switch session[index] {
        case .web(let tab):
            tab.shutdown()
        case .terminal(let tab):
            tab.shutdown()
        }
        let closingActive = session[index].id == activeID
        session.remove(at: index)
        if session.isEmpty {
            closeConfirmed = true
            window?.close()
            return
        }
        if closingActive {
            let nextIndex = min(index, session.count - 1)
            var chosen = session[nextIndex]
            if !settings.settings.tabVisibility.allows(chosen.kind) {
                let after = session.dropFirst(nextIndex).first { settings.settings.tabVisibility.allows($0.kind) }
                let before = session.prefix(nextIndex).last { settings.settings.tabVisibility.allows($0.kind) }
                if let after {
                    chosen = after
                } else if let before {
                    chosen = before
                }
            }
            activateTab(id: chosen.id, switching: true)
        }
        syncBars(progressOnly: false)
        noteSessionChange()
    }

    private func confirmCloseTerminal(then close: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Close this terminal?"
        alert.informativeText = "A process is still running. Closing stops it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            close()
        }
    }

    /// The command is shown in full. Cancel leaves the tab in place and does not start a process.
    private func confirmRun(_ terminal: TerminalTab) {
        let alert = NSAlert()
        alert.messageText = "Run this command?"
        alert.informativeText = terminal.command
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.session.contains(where: { $0.id == terminal.id }) else { return }
            self.terminalBookmarks.confirm(id: terminal.bookmarkID)
            terminal.start()
        }
    }

    private func tabItem(for tab: BrowserTab, selected: Bool) -> TabStripItem {
        switch tab.surface {
        case .newTab:
            return TabStripItem(
                id: tab.id,
                title: "New Tab",
                badgeLetter: "+",
                badgeHex: SiteBadge.newTabHex,
                favicon: nil,
                selected: selected
            )
        case .bookmarks:
            return TabStripItem(
                id: tab.id,
                title: tab.title,
                badgeLetter: "B",
                badgeHex: SiteBadge.listHex,
                favicon: nil,
                selected: selected
            )
        case .web:
            let host = tab.displayedURL?.host ?? ""
            let source = tab.title == "New Tab" && !host.isEmpty ? host : tab.title
            return TabStripItem(
                id: tab.id,
                title: tab.title,
                badgeLetter: SiteBadge.letter(forTitle: source),
                badgeHex: SiteBadge.colorHex(forHost: host),
                favicon: tab.favicon,
                selected: selected
            )
        }
    }

    private func commit(text: String) {
        guard let tab = activeTab else { return }
        let engine = settings.settings.resolvedSearchEngine()
        guard let url = InputResolver(engine: engine).resolve(text) else { return }
        tab.load(url: url, userTypedFile: url.scheme?.lowercased() == "file")
        if tab.surface == .web {
            window?.makeFirstResponder(tab.webView)
        }
    }

    private func openBookmark(_ bookmark: Bookmark) {
        guard let url = URL(string: bookmark.url) else { return }
        loadInActiveTab(url: url, userTypedFile: url.scheme?.lowercased() == "file")
    }

    private func presentMediaPrompt(
        tab: BrowserTab,
        origin: String,
        kind: MediaCaptureKind,
        completion: @escaping (Bool) -> Void
    ) {
        dismissMediaPrompt(grant: false)
        let prompt = MediaPermissionPromptController(origin: origin, kind: kind)
        mediaPrompt = prompt
        mediaPromptTabID = tab.id
        prompt.onChoice = { [weak self] choice in
            guard let self else {
                completion(false)
                return
            }
            self.mediaPrompt = nil
            self.mediaPromptTabID = nil
            let applied = MediaPermissionPolicy.apply(choice)
            if let stored = applied.stored {
                self.mediaPermissions.set(stored, origin: origin, kind: kind)
            }
            completion(applied.grant)
        }
        guard let sheet = prompt.window, let host = window else {
            completion(false)
            return
        }
        host.beginSheet(sheet) { _ in }
        axBridge.bridged = sheet.contentView
    }

    private func dismissMediaPrompt(grant: Bool) {
        _ = grant
        guard let prompt = mediaPrompt else { return }
        mediaPrompt = nil
        mediaPromptTabID = nil
        prompt.onChoice?(.deny)
        prompt.onChoice = nil
        axBridge.bridged = nil
        if let sheet = prompt.window {
            window?.endSheet(sheet)
        }
    }

    private func present(_ alert: NSAlert) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// Coalesce to one main-queue pass. Layout can run many times before the window is shown.
    private func scheduleTrafficLightPlacement() {
        guard !trafficPlacementQueued else { return }
        trafficPlacementQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trafficPlacementQueued = false
                self.positionTrafficLightContainers(endLayoutPass: true)
            }
        }
    }

    /// Moves each stoplight so its midline matches the strip. X stays put.
    /// Full screen, a hidden close button, or a window without a title keep the system frames.
    /// A hidden title (`titleVisibility == .hidden`) is the normal custom bar and is still centered.
    ///
    /// The system titlebar is shorter than the 38-point strip. Centering a button in that
    /// titlebar leaves it 5 points off the strip's midline. Growing the titlebar container
    /// equally up and down keeps that same midline, so the button views are shifted instead.
    /// `endLayoutPass` clears the theme frame's layout flag so the shift is not reset.
    fileprivate func positionTrafficLightContainers(endLayoutPass: Bool) {
        guard !positioningTrafficLights, let window else { return }
        let close = window.standardWindowButton(.closeButton)
        let miniaturize = window.standardWindowButton(.miniaturizeButton)
        let zoom = window.standardWindowButton(.zoomButton)
        close?.setAccessibilityIdentifier("app1.traffic.close")
        miniaturize?.setAccessibilityIdentifier("app1.traffic.min")
        zoom?.setAccessibilityIdentifier("app1.traffic.zoom")
        let fullscreen = window.styleMask.contains(.fullScreen)
        let titled = window.styleMask.contains(.titled)
        let buttonsHidden = close?.isHidden == true || close?.superview?.isHidden == true
        if close == nil || fullscreen || !titled || buttonsHidden {
            return
        }
        guard let close else { return }
        positioningTrafficLights = true
        // Set before any frame change so a re-entrant theme-frame layout cannot undo it.
        ThemeFrameTrafficHook.beginPlacingButtons()
        defer {
            positioningTrafficLights = false
            ThemeFrameTrafficHook.endPlacingButtons()
        }
        let barInWindow = bar.convert(bar.bounds, to: nil)
        guard barInWindow.height > 2 else { return }
        if let theme = window.contentView?.superview {
            var ancestor: NSView? = close.superview
            while let view = ancestor, view !== theme {
                view.wantsLayer = true
                view.layer?.masksToBounds = false
                ancestor = view.superview
            }
        }
        let buttons = [close, miniaturize, zoom].compactMap { $0 }
        for button in buttons {
            guard let host = button.superview else { continue }
            let buttonInWindow = button.convert(button.bounds, to: nil)
            let delta = barInWindow.midY - buttonInWindow.midY
            guard abs(delta) > 0.5 else { continue }
            let originInWindow = host.convert(button.frame.origin, to: nil)
            let moved = NSPoint(x: originInWindow.x, y: originInWindow.y + delta)
            button.setFrameOrigin(host.convert(moved, from: nil))
        }
        if endLayoutPass {
            window.contentView?.superview?.needsLayout = false
            close.superview?.needsLayout = false
            close.superview?.superview?.needsLayout = false
        }
    }

    @objc private func emitWindowIDFallback() {
        emitWindowID()
    }

    private func emitWindowID() {
        guard printsWindowIdentity, !didEmitWindowID, let window, window.isVisible else { return }
        didEmitWindowID = true
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(emitWindowIDFallback), object: nil)
        DispatchQueue.main.async { [weak self] in
            self?.writeWindowID()
        }
    }

    private func writeWindowID() {
        guard let number = window?.windowNumber else { return }
        let line = "APP1_WINDOW_ID=\(number)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        fflush(stdout)
    }

    private static func allowsBookmark(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    @objc private func backTapped() { goBack() }
    @objc private func forwardTapped() { goForward() }
    @objc private func reloadTapped() { reloadOrStop() }
    @objc private func sidebarTapped() { showBookmarks() }

    @objc private func downloadsTapped() {
        if downloadsPopover.isShown {
            downloadsPopover.performClose(nil)
            return
        }
        showDownloadsPopover()
    }

    private func showDownloadsPopover() {
        guard !DownloadManager.shared.items.isEmpty else { return }
        downloadsPopoverController.reload()
        downloadsButton.isHidden = false
        downloadsPopover.show(relativeTo: downloadsButton.bounds, of: downloadsButton, preferredEdge: .maxY)
        downloadsButton.extraAccessibilityChild = downloadsPopoverController.view
        if opensDownloadsFromHook {
            emitPopoverID()
        }
    }

    private func syncDownloadsButton() {
        let items = DownloadManager.shared.items
        let visible = !items.isEmpty
        downloadsButton.isHidden = !visible
        downloadsWidth?.constant = visible ? MonoMetrics.control : 0
        downloadsGap?.isActive = visible
        healthToAddressGap?.isActive = !visible
        downloadsButton.tint = DownloadManager.shared.hasActiveDownload ? Theme.accent : Theme.mute
        if !visible, downloadsPopover.isShown {
            downloadsPopover.performClose(nil)
        }
    }

    private func pulseDownloadsButton() {
        syncDownloadsButton()
        downloadsButton.tint = Theme.accent
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            MainActor.assumeIsolated {
                self?.downloadsButton.tint = Theme.mute
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    MainActor.assumeIsolated {
                        self?.syncDownloadsButton()
                    }
                }
            }
        }
    }

    private func emitPopoverID() {
        guard !didEmitPopoverID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.didEmitPopoverID else { return }
                let number = self.downloadsPopover.contentViewController?.view.window?.windowNumber
                    ?? self.downloadsButton.window?.windowNumber
                guard let number else { return }
                self.didEmitPopoverID = true
                let line = "APP1_POPOVER_WINDOW_ID=\(number)\n"
                FileHandle.standardOutput.write(Data(line.utf8))
                fflush(stdout)
            }
        }
    }
}

extension BrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeTab(_:)) {
            return !session.isEmpty
        }
        return true
    }
}
