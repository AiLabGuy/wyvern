// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore
import Darwin
import ObjectiveC
import QuartzCore
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
        "wyvern.bar"
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !wantsLayer {
            wantsLayer = true
        }
    }

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

/// Last placement of one source tab's DevTools pane during this window's session.
struct DevToolsPlaceMemory: Equatable {
    var side: DevToolsSide
    var pageFraction: Double
    var poppedOut: Bool
    var windowed: Bool
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
    private let tiles = WindowTiles()
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
    private let blockBadge = BlockedCountBadge()
    private let blockPopover = NSPopover()
    private let blockPopoverController = BlockedCountPopoverController()
    private var blockListObserver: NSObjectProtocol?
    private var downloadsWidth: NSLayoutConstraint?
    private var healthWidth: NSLayoutConstraint?
    private let splitButton = SplitViewButton()
    private let toolbarCluster = NSStackView()
    private let layoutPopover = NSPopover()
    private let layoutPicker = SplitLayoutPicker()
    private var previousActiveID: UUID?
    private var panePages: [UUID: NewTabPageView] = [:]
    private var paneBookmarkPages: [UUID: BookmarksPageView] = [:]
    private var healthArchive = PaneHealthArchive<NetworkHealthSnapshot>()
    private var healthTabID: UUID?
    private var tileStyleToken = 0
    private var styledToken: [UUID: Int] = [:]
    private var announcedPaneID: UUID?
    /// Last content minimum written for the split. Resize does not write it again.
    private var appliedTileContentMinWidth: CGFloat?
    private var dragPreview: TileDropPreview?
    private var dragPreviewTimer: Timer?
    private var dragPreviewKey: String?
    private var pendingPreviewRect = NSRect.zero
    private var tileDragMonitor: Any?
    private var tileDragCancelled = false
    private var blockWidth: NSLayoutConstraint?
    private var settingsObserver: NSObjectProtocol?
    private var didEmitWindowID = false
    private var didEmitPopoverID = false
    private var positioningTrafficLights = false
    /// One deferred stoplight pass is enough until the next layout.
    private var trafficPlacementQueued = false
    private var closeConfirmed = false
    private var barHeightConstraint: NSLayoutConstraint?
    private var guidedTour: GuidedTourOverlay?
    private let linkedChip = DevToolsLinkedChip()
    private var linkedChipWidth: NSLayoutConstraint?
    private var linkedChipLeading: NSLayoutConstraint?
    private let splitToast = SplitFullToast()
    private var toastTimer: Timer?
    private var toastUndoLayout: TileLayout?
    private var toastUndoDevToolsID: UUID?
    private var devToolsMemory: [UUID: DevToolsPlaceMemory] = [:]
    private var devToolsHiddenAt: [UUID: Date] = [:]
    /// Hidden inspector kept for 30 seconds after the DevTools tab closes, keyed by source id.
    private var suspendedDevTools: [UUID: DevToolsTab] = [:]
    private var isSyncingBars = false
    private var standbyHosts: [UUID: WebInspectorHost] = [:]
    private var standbyViews: [UUID: DevToolsStandbyView] = [:]
    private var menuTrackingObserver: NSObjectProtocol?
    private var pendingPreviewCaption = ""
    private var didAlertDevToolsFailure = false
    private var inspectionOpenInFlight: Set<UUID> = []
    /// Recent external-scheme confirm sheets. A page cannot raise an unbounded prompt flood.
    private var externalPromptTimes: [Date] = []

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
            forName: .wyvernBookmarksDidChange,
            object: bookmarks,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncBars(progressOnly: false)
            }
        }
        faviconObserver = NotificationCenter.default.addObserver(
            forName: .wyvernFaviconsDidClear,
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
            forName: .wyvernDownloadsDidChange,
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
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.noteInspectionMenus()
            }
        }
        linkedChip.onActivate = { [weak self] in
            self?.showSourceOfActiveDevTools()
        }
        splitToast.onUndo = { [weak self] in
            self?.undoFullSplitToast()
        }
        healthService.enabled = settings.settings.netHealthEnabled
        healthService.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                // `stop()` publishes an empty host. Keep the pane's real samples for the next focus.
                if let id = self.healthTabID ?? self.activeID, !snapshot.host.isEmpty {
                    self.healthArchive.remember(snapshot, for: id)
                }
                self.healthPanel?.apply(snapshot)
                self.healthBadge.snapshot = self.labeledHealth(snapshot)
            }
        }
        healthBadge.target = self
        healthBadge.action = #selector(healthBadgeTapped)
        blockBadge.target = self
        blockBadge.action = #selector(blockBadgeTapped)
        blockPopover.contentViewController = blockPopoverController
        blockPopover.behavior = .transient
        blockPopover.animates = false
        blockPopover.delegate = self
        blockPopoverController.onPause = { [weak self] paused in
            self?.setFocusedSitePaused(paused)
        }
        blockPopoverController.onTurnOn = { [weak self] in
            BlockListController.shared.setBlockingEnabled(true)
            self?.blockPopoverController.noteUserChange(success: true)
            self?.refreshBlockPopover()
        }
        blockPopoverController.onReload = { [weak self] in
            self?.reloadBlockBadgeTab()
        }
        blockPopoverController.onOpenSettings = { [weak self] in
            self?.blockPopover.performClose(nil)
            (NSApp.delegate as? AppDelegate)?.showBlockListSettings(nil)
        }
        blockListObserver = NotificationCenter.default.addObserver(
            forName: .wyvernBlockListStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.applyBlockListChange(note)
            }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .wyvernSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyNetHealthSetting()
                if let current = self?.settings.settings {
                    BrowserTab.hardwareAcceleration = current.hardwareAcceleration
                    BrowserTab.defaultFontSize = current.defaultFontSize
                    BrowserTab.defaultZoomPercent = current.defaultZoomPercent
                    BrowserTab.developerToolsEnabled = current.developerToolsEnabled
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

    var canGoBack: Bool { pageTab()?.canGoBack ?? false }
    var canGoForward: Bool { pageTab()?.canGoForward ?? false }
    var isLoadingPage: Bool { pageTab()?.surface == .web && pageTab()?.isLoading == true }
    /// Visible tabs only. Hidden kinds stay in the session and are not numbered.
    var tabCount: Int { visibleSession().count }
    var canBookmarkCurrent: Bool { Self.allowsBookmark(pageTab()?.displayedURL) }

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
        syncSplitChrome()
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
        autoplayURL: URL? = nil,
        deferPresentation: Bool = false
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
        let members = TileStripGroup.memberIDs(
            savedSplitTabIDs: tiles.tabIDs(),
            splitExists: tiles.hasSavedSplit
        )
        let insertAt = TileStripGroup.insertionIndex(
            session: session.map(\.id),
            afterID: activeID,
            members: members
        )
        session.insert(.web(tab), at: insertAt)
        activeID = tab.id
        ensureStandby(for: tab)
        if deferPresentation {
            noteSessionChange()
            return tab
        }
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
        // Closing DevTools keeps the inspector for 30 seconds. Closing the source shuts it down.
        let parking = devToolsTab(id: id)
        if let parking {
            parking.suspend()
            suspendedDevTools[parking.sourceID] = parking
            devToolsHiddenAt[parking.sourceID] = Date()
            armDevToolsExpiry(sourceID: parking.sourceID)
        }
        removeSession(id: id)
        guard let parking, window != nil, suspendedDevTools[parking.sourceID] === parking else { return }
        parking.container.alphaValue = 0
        if parking.container.superview == nil, let content = window?.contentView {
            parking.container.frame = NSRect(x: -2000, y: -2000, width: 800, height: 600)
            content.addSubview(parking.container)
        }
    }

    /// Removes the tab without shutting it down. A web view keeps its history.
    /// A terminal process keeps running; drag-out does not start it again.
    @discardableResult
    func detachTab(at index: Int) -> SessionTab? {
        guard session.indices.contains(index) else { return nil }
        let item = session.remove(at: index)
        let wasActive = item.id == activeID
        let preferred = tiles.remove(tabID: item.id)
        switch item {
        case .web(let tab):
            tab.host = nil
            unembed(tab.webView)
        case .terminal(let tab):
            unembed(tab.view)
        case .devtools(let tab):
            unembed(tab.container)
        }
        if session.isEmpty {
            activeID = nil
            tabRegion.update(items: [])
            return item
        }
        if wasActive {
            activateTab(id: resolvedCloseTarget(preferred: preferred, index: index), switching: true)
        }
        syncBars(progressOnly: false)
        noteSessionChange()
        if !session.isEmpty {
            focusPaneContentIfNeeded()
        }
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
        if case .devtools(let tools) = tab {
            tools.container.alphaValue = 1
            tools.host.reparentCompanion()
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

    /// A new press clears a cancelled drag so the next gesture is live.
    func prepareTabDrag() {
        tileDragCancelled = false
    }

    /// Reads and clears the Esc flag. Mouse-up captures it before the drop runs on the next turn.
    func consumeTileDragCancellation() -> Bool {
        let cancelled = tileDragCancelled
        tileDragCancelled = false
        return cancelled
    }

    /// Drop of a tab drag. A strip under the pointer wins. Otherwise a release more than
    /// `TabDrag.detachDistance` from this strip, or outside this window, detaches the tab.
    /// The only tab in a window moves that window instead of leaving an empty one.
    func finishTabDrag(tabID: UUID, screenPoint: NSPoint, cursorOffsetInTab: NSPoint, cancelled: Bool = false) {
        let dropped = cancelled || tileDragCancelled
        tileDragCancelled = false
        endTileDragChrome()
        guard !dropped else { return }
        guard let from = indexOfTab(id: tabID) else { return }
        if pageContains(screenPoint) {
            if let target = tileDropTarget(at: screenPoint, dragging: tabID) {
                if tileDropCanApply(tabID: tabID, target: target) {
                    performTileDrop(tabID: tabID, target: target)
                }
                // An edge that cannot tile still ends the drag. It does not detach.
                return
            }
            let vertical = tabRegion.verticalDistance(toScreenPoint: screenPoint)
            if vertical <= TabDrag.detachDistance {
                // Near the strip, with no tile target, the drop cancels.
                return
            }
        }
        if let (target, visibleIndex) = Self.stripTarget(at: screenPoint) {
            let destination = target.sessionIndex(forVisibleDrop: visibleIndex)
            if target === self {
                removeFromSplitIfDroppedOutside(tabID: tabID, visibleIndex: visibleIndex)
                moveTab(from: from, to: destination)
            } else if let tab = detachTab(at: from) {
                target.adopt(tab: tab, at: destination)
                movePartnerDevTools(of: tab, to: target)
                noteDevToolsDraggedToAnotherWindow(tab)
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
                if case .web(let web) = tab, let home = windowHosting(tab: web.id) {
                    movePartnerDevTools(of: tab, to: home)
                }
                noteDevToolsDraggedToAnotherWindow(tab)
            }
            return
        }
        let visibleIndex = tabRegion.dropIndex(atScreenPoint: screenPoint)
        removeFromSplitIfDroppedOutside(tabID: tabID, visibleIndex: visibleIndex)
        moveTab(from: from, to: sessionIndex(forVisibleDrop: visibleIndex))
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
        var replacedID: UUID?
        if !openInNewTab, let current = activeTerminalTab {
            replacedID = current.id
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
        if let replacedID {
            tiles.replace(tabID: replacedID, with: tab.id, kind: .terminal)
        }
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
        guard let tab = pageTab(), tab.surface == .web else { return }
        tab.webView.goBack()
    }

    func goForward() {
        guard let tab = pageTab(), tab.surface == .web else { return }
        tab.webView.goForward()
    }

    func reloadPage() {
        guard let tab = pageTab(), tab.surface == .web else { return }
        tab.webView.reload()
    }

    /// Reloads every web tab in this window. Settings uses it for "Reload All".
    func reloadAllWebTabs() {
        for item in session {
            if case .web(let tab) = item, tab.surface == .web {
                tab.webView.reload()
            }
        }
    }

    /// Blocked-request count for the toolbar badge.
    /// A visible split counts the focused pane, not the strip's selected tab when they differ.
    /// A terminal pane counts as zero.
    func blockedCountForFocusedTab(_ tab: BrowserTab?) -> Int {
        switch blockBadgeSubject() {
        case .terminal:
            return 0
        case .web(let focused):
            return focused.blockedRequestCount
        case .strip:
            return tab?.blockedRequestCount ?? 0
        }
    }

    func stopLoading() {
        guard let tab = pageTab(), tab.surface == .web else { return }
        tab.webView.stopLoading()
    }

    func reloadOrStop() {
        guard let tab = pageTab(), tab.surface == .web else { return }
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
        guard let tab = pageTab(), let url = tab.displayedURL, Self.allowsBookmark(url) else { return }
        let raw = url.absoluteString
        if let existing = bookmarks.bookmark(matchingURL: raw) {
            bookmarks.remove(id: existing.id)
        } else {
            addBookmark()
        }
    }

    /// Address-bar shortcut adds the current page. It does not remove an existing bookmark.
    func addBookmark() {
        guard let tab = pageTab(), let url = tab.displayedURL, Self.allowsBookmark(url) else { return }
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
        updateTileWindowMinSize()
        rememberDevToolsWindowFrameIfNeeded()
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
        var tabs: [SessionTabSnapshot] = []
        var indexByID: [UUID: Int] = [:]
        for item in session {
            let snapshot: SessionTabSnapshot
            switch item {
            case .web(let tab):
                snapshot = SessionTabSnapshot(kind: .web, url: tab.displayedURL?.absoluteString, terminalBookmarkID: nil)
            case .terminal(let tab):
                snapshot = SessionTabSnapshot(kind: .terminal, url: nil, terminalBookmarkID: tab.bookmarkID)
            case .devtools(let tab):
                snapshot = SessionTabSnapshot(
                    kind: .devtools,
                    url: tab.sourceURL?.absoluteString,
                    devtoolsSourceIndex: indexByID[tab.sourceID]
                )
            }
            indexByID[item.id] = tabs.count
            tabs.append(snapshot)
        }
        let selected = activeID.flatMap { indexByID[$0] } ?? 0
        let tile = tiles.capture { indexByID[$0] }
        return SessionWindowSnapshot(tabs: tabs, selectedIndex: selected, tile: tile)
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
            case .devtools(let tab):
                return TabSearchEntry(
                    id: tab.id,
                    title: tab.displayTitle,
                    url: tab.sourceURL?.absoluteString ?? "",
                    kind: .devtools
                )
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
            if case .devtools(let tab) = item {
                tab.shutdown()
            }
        }
        for item in session {
            switch item {
            case .web(let tab):
                tab.shutdown()
            case .terminal(let tab):
                tab.shutdown()
            case .devtools:
                break
            }
        }
        session.removeAll()
        activeID = nil
        tiles.clear()
        var created: [Int: UUID] = [:]
        for (index, record) in snapshot.tabs.enumerated() {
            if record.kind == .devtools { continue }
            let before = session.count
            appendRestored(record)
            if session.count > before, let id = session.last?.id {
                created[index] = id
            }
        }
        for (index, record) in snapshot.tabs.enumerated() where record.kind == .devtools {
            guard let sourceIndex = record.devtoolsSourceIndex,
                  let sourceID = created[sourceIndex],
                  let source = webTab(id: sourceID) else { continue }
            let tools = makeRestoredDevTools(source: source)
            session.append(.devtools(tools))
            created[index] = tools.id
        }
        guard !session.isEmpty else { return false }
        tiles.restore(snapshot.tile) { index in created[index] }
        let chosenIndex = created.keys.filter { $0 <= snapshot.selectedIndex }.max()
        let chosen = chosenIndex.flatMap { created[$0] } ?? session[0].id
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
                tab.applyInspectability()
                ensureStandby(for: tab)
            }
        }
    }

    private func appendRestored(_ record: SessionTabSnapshot) {
        switch record.kind {
        case .web:
            let tab = addTab(loadBlank: false)
            switch SessionRestorePolicy.webLoad(for: record.url) {
            case .newTab:
                tab.show(.newTab)
            case .web(let url):
                tab.load(url: url, userTypedFile: false)
            case .localDocument(let url):
                tab.load(url: url, userTypedFile: true)
            }
        case .terminal:
            guard let id = record.terminalBookmarkID else { return }
            appendTerminalBookmark(id: id)
        case .devtools:
            // Restored in a second pass so the source tab already exists.
            return
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
        if let blockListObserver {
            NotificationCenter.default.removeObserver(blockListObserver)
            self.blockListObserver = nil
        }
        downloadsPopover.performClose(nil)
        blockPopover.performClose(nil)
        terminalPicker.dismiss()
        rememberDevToolsWindowFrameIfNeeded()
        toastTimer?.invalidate()
        toastTimer = nil
        if let menuTrackingObserver {
            NotificationCenter.default.removeObserver(menuTrackingObserver)
            self.menuTrackingObserver = nil
        }
        tiles.release()
        dismissMediaPrompt(grant: false)
        if let sheet = importSheet?.window {
            window?.endSheet(sheet)
        }
        for item in session {
            if case .devtools(let tab) = item {
                tab.shutdown()
            }
        }
        for item in session {
            switch item {
            case .web(let tab):
                tab.shutdown()
            case .terminal(let tab):
                tab.shutdown()
            case .devtools:
                break
            }
        }
        for host in standbyHosts.values {
            host.shutdown()
        }
        standbyHosts.removeAll()
        for parked in suspendedDevTools.values {
            parked.shutdown()
        }
        suspendedDevTools.removeAll()
        devToolsHiddenAt.removeAll()
        session.removeAll()
        onClose?()
    }

    func browserTabDidUpdate(_ tab: BrowserTab, progressOnly: Bool) {
        if let tools = devToolsTab(forSource: tab.id) {
            tools.noteSourceTitle(tab.title)
        }
        if !progressOnly {
            ensureStandby(for: tab)
        }
        let showsThisPage = tab.id == activeTab?.id || activeDevToolsTab()?.sourceID == tab.id
        guard showsThisPage || !progressOnly else { return }
        if showsThisPage || session.contains(where: { $0.id == tab.id }) {
            syncBars(progressOnly: progressOnly && showsThisPage)
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
        guard ExternalLaunchPolicy.allowsConfirmation(url) else { return }
        let now = Date()
        let gate = ExternalPromptGate.allow(recent: externalPromptTimes, now: now)
        externalPromptTimes = gate.retained
        guard gate.allow else { return }
        let alert = NSAlert()
        alert.messageText = "Open this link outside \(AppInfo.displayName)?"
        alert.informativeText = ExternalLaunchPolicy.promptText(for: url)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn, ExternalLaunchPolicy.allowsConfirmation(url) {
                    NSWorkspace.shared.open(url)
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn, ExternalLaunchPolicy.allowsConfirmation(url) {
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
        let toolsActive = activeDevToolsTab()?.sourceID == tab.id
        guard tab.id == activeID || toolsActive else { return }
        feedHealth(host: host, url: tab.displayedURL, rememberAs: tab.id)
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
                self?.paneBookmarkPages.values.forEach { $0.reload() }
            }
        }
    }

    /// The Develop menu inspects the focused web tab, including the focused pane of a split.
    /// A focused DevTools tab acts on its source page. Nil for a terminal tab, the new-tab page,
    /// bookmarks, or when Show Develop menu is off.
    func focusedWebInspectorTarget() -> BrowserTab? {
        if let tools = activeDevToolsTab() {
            let source = webTab(id: tools.sourceID) ?? webTabInAnyWindow(id: tools.sourceID)
            if let source, source.surface == .web {
                return source
            }
            return nil
        }
        guard let tab = activeTab else { return nil }
        guard DeveloperTools.shouldBeInspectable(
            surface: WebContentSurface(tab.surface),
            setting: settings.settings.developerToolsEnabled
        ) else {
            return nil
        }
        return tab
    }

    /// ⌥⌘I can open an inspectable page or hide a DevTools tab that is already focused.
    var canToggleWebInspector: Bool {
        if activeDevToolsTab() != nil { return true }
        return focusedWebInspectorTarget() != nil
    }

    /// Hide while this window is showing that page's DevTools tab.
    var devToolsMenuTitleIsHide: Bool {
        if activeDevToolsTab() != nil { return true }
        if let source = focusedWebInspectorTarget(), let tools = devToolsTab(forSource: source.id) {
            return devToolsIsShowing(tools)
        }
        return false
    }

    /// The page navigation commands act on. A focused DevTools tab uses its source page.
    private func pageTab() -> BrowserTab? {
        if let tools = activeDevToolsTab() {
            return webTab(id: tools.sourceID) ?? webTabInAnyWindow(id: tools.sourceID)
        }
        return activeTab
    }

    /// The active web tab. Nil while a terminal tab or a DevTools tab is selected.
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
        bar.setAccessibilityIdentifier("wyvern.bar")
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
        backButton.setAccessibilityIdentifier("wyvern.back")
        configureTool(forwardButton, glyph: .forward, label: "Forward", action: #selector(forwardTapped))
        configureTool(reloadButton, glyph: .reload, label: "Reload", action: #selector(reloadTapped))

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.onSubmit = { [weak self] text in self?.commit(text: text) }
        addressField.onToggleStar = { [weak self] in self?.toggleBookmark() }

        tabRegion.onSelect = { [weak self] id in
            guard let self else { return }
            self.activateTab(id: id, switching: true)
            self.syncBars(progressOnly: false)
            if self.tiles.isSplitVisible(activeID: id) {
                self.focusPaneContent()
            }
        }
        tabRegion.onClose = { [weak self] id in
            self?.closeTab(id: id)
        }
        tabRegion.contextMenuForTab = { [weak self] id in
            self?.tabContextMenu(for: id)
        }
        tabRegion.onNewTab = { [weak self] in
            _ = self?.addTab()
        }
        tabRegion.onTabDrag = { [weak self] id, point in
            self?.updateTileDrag(tabID: id, screenPoint: point)
        }
        tiles.contentForTab = { [weak self] id, focused in
            self?.tileContent(id: id, focused: focused)
        }
        tiles.onFocusTab = { [weak self] id in
            guard let self else { return }
            if self.activeID != id {
                self.activateTab(id: id, switching: true)
                self.syncBars(progressOnly: false)
                self.focusPaneContent()
            }
            self.syncBlockBadgeForFocusedPane()
        }
        tiles.onChange = { [weak self] in
            self?.noteSessionChange()
        }
        tiles.canvas.devToolsMoveMenu = { [weak self] id in
            self?.devToolsMoveMenu(for: id)
        }
        tiles.canvas.onPopOut = { [weak self] id in
            self?.popOutDevTools(id: id)
        }
        tiles.canvas.onDevToolsOverflow = { [weak self] id, anchor in
            self?.showDevToolsOverflow(id: id, anchor: anchor)
        }
        tiles.pendingMakeMain = { [weak self] id in
            guard let self else { return }
            self.activateTab(id: id, switching: false)
            self.performUnsplit()
        }
        tiles.pendingClose = { [weak self] id in
            self?.closeTab(id: id)
        }
        tiles.canvas.onAppearance = { [weak self] in
            guard let self else { return }
            self.tileStyleToken += 1
            if self.tiles.isSplitVisible(activeID: self.activeID) {
                self.tiles.present()
            }
        }
        tiles.canvas.onStructureChange = { [weak self] in
            guard let self, self.responderIsInsideCanvas() else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.focusPaneContentIfNeeded()
                }
            }
        }
        layoutPicker.onChoose = { [weak self] arrangement in
            self?.layoutPopover.performClose(nil)
            self?.applyArrangement(arrangement)
        }
        let layoutController = NSViewController()
        layoutPicker.frame = NSRect(x: 0, y: 0, width: 260, height: 46)
        layoutController.view = layoutPicker
        layoutPopover.contentViewController = layoutController
        layoutPopover.contentSize = NSSize(width: 260, height: 46)
        layoutPopover.behavior = .transient
        layoutPopover.animates = false
        splitButton.glyph = .split2
        splitButton.pointSize = MonoMetrics.navGlyph
        splitButton.tint = Theme.mute
        splitButton.fill = .clear
        splitButton.toolTip = "Split View"
        splitButton.setAccessibilityLabel("Split View")
        splitButton.setAccessibilityIdentifier("wyvern.toolbar.splitView")
        splitButton.onPress = { [weak self] in
            self?.splitViewClicked()
        }
        splitButton.onLongPress = { [weak self] in
            self?.showLayoutPopover()
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
        linkedChip.translatesAutoresizingMaskIntoConstraints = false
        linkedChip.isHidden = true
        toolbar.addSubview(linkedChip)
        toolbar.addSubview(addressField)
        bar.addSubview(tabRegion)
        toolbarCluster.orientation = .horizontal
        toolbarCluster.alignment = .centerY
        toolbarCluster.spacing = MonoMetrics.itemGap
        toolbarCluster.detachesHiddenViews = true
        toolbarCluster.translatesAutoresizingMaskIntoConstraints = false
        toolbarCluster.setAccessibilityElement(false)
        toolbarCluster.setContentHuggingPriority(.required, for: .horizontal)
        toolbarCluster.setContentCompressionResistancePriority(.required, for: .horizontal)
        splitButton.translatesAutoresizingMaskIntoConstraints = false
        blockBadge.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(toolbarCluster)
        toolbarCluster.addArrangedSubview(splitButton)
        toolbarCluster.addArrangedSubview(downloadsButton)
        toolbarCluster.addArrangedSubview(blockBadge)
        toolbar.addSubview(healthBadge)
        bar.addSubview(appearanceProbe)
        axBridge.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(axBridge)
        pageHost.addSubview(webContainer)
        pageHost.addSubview(terminalHost)
        pageHost.addSubview(bookmarksPage)
        pageHost.addSubview(newTabPage)
        tiles.canvas.translatesAutoresizingMaskIntoConstraints = false
        tiles.canvas.isHidden = true
        pageHost.addSubview(tiles.canvas)
        splitToast.translatesAutoresizingMaskIntoConstraints = false
        splitToast.isHidden = true
        pageHost.addSubview(splitToast)

        healthBadge.translatesAutoresizingMaskIntoConstraints = false
        appearanceProbe.isHidden = false
        appearanceProbe.alphaValue = 0.01
        appearanceProbe.isBezeled = false
        appearanceProbe.drawsBackground = false
        appearanceProbe.isEditable = false
        appearanceProbe.isSelectable = false
        appearanceProbe.translatesAutoresizingMaskIntoConstraints = false
        appearanceProbe.setAccessibilityIdentifier("wyvern.appearance")
        appearanceProbe.setAccessibilityElement(true)
        appearanceProbe.setAccessibilityRole(.staticText)
        preferenceProbe.isHidden = false
        preferenceProbe.alphaValue = 0.01
        preferenceProbe.isBezeled = false
        preferenceProbe.drawsBackground = false
        preferenceProbe.isEditable = false
        preferenceProbe.isSelectable = false
        preferenceProbe.translatesAutoresizingMaskIntoConstraints = false
        preferenceProbe.setAccessibilityIdentifier("wyvern.appearance.preference")
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
        downloadsButton.setAccessibilityIdentifier("wyvern.downloads.button")
        downloadsButton.target = self
        downloadsButton.action = #selector(downloadsTapped)
        downloadsButton.translatesAutoresizingMaskIntoConstraints = false
        downloadsButton.isHidden = true

        blockBadge.translatesAutoresizingMaskIntoConstraints = false
        blockBadge.isHidden = true

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

            linkedChip.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: linkedChip.trailingAnchor, constant: MonoMetrics.itemGap),
            addressField.trailingAnchor.constraint(equalTo: toolbarCluster.leadingAnchor, constant: -MonoMetrics.itemGap),
            addressField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: MonoMetrics.urlHeight),

            tabRegion.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: MonoMetrics.contentLeading),
            tabRegion.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -MonoMetrics.barTrailing),
            tabRegion.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            tabRegion.heightAnchor.constraint(equalToConstant: MonoMetrics.tabHeight),

            splitButton.widthAnchor.constraint(equalToConstant: MonoMetrics.control),
            splitButton.heightAnchor.constraint(equalToConstant: MonoMetrics.control),
            downloadsButton.heightAnchor.constraint(equalToConstant: MonoMetrics.control),
            blockBadge.heightAnchor.constraint(equalToConstant: MonoMetrics.blockBadgeHeight),

            toolbarCluster.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbarCluster.trailingAnchor.constraint(equalTo: healthBadge.leadingAnchor, constant: -MonoMetrics.itemGap),

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
            axBridge.heightAnchor.constraint(equalToConstant: 1),

            splitToast.centerXAnchor.constraint(equalTo: pageHost.centerXAnchor),
            splitToast.topAnchor.constraint(equalTo: pageHost.topAnchor, constant: 16),
            splitToast.heightAnchor.constraint(equalToConstant: 36)
        ])
        let chipLeading = linkedChip.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor)
        chipLeading.isActive = true
        linkedChipLeading = chipLeading
        let chipWidth = linkedChip.widthAnchor.constraint(equalToConstant: 0)
        chipWidth.isActive = true
        linkedChipWidth = chipWidth
        let width = downloadsButton.widthAnchor.constraint(equalToConstant: 0)
        let healthW = healthBadge.widthAnchor.constraint(equalToConstant: 92)
        let blockW = blockBadge.widthAnchor.constraint(equalToConstant: 0)
        healthWidth = healthW
        healthW.isActive = true
        downloadsWidth = width
        width.isActive = true
        blockWidth = blockW
        blockW.isActive = true
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
        pinToEdges(tiles.canvas)
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
        healthBadge.setAccessibilityElement(on)
        let width = CGFloat(BlockedBadgeVisibility.constraintWidth(visible: on, preferredWidth: 92))
        if on {
            healthWidth?.constant = width
            healthBadge.isHidden = false
        } else {
            healthBadge.isHidden = true
            healthWidth?.constant = width
        }
        syncRightCluster()
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

    private func feedHealth(host: String?, url: URL?, rememberAs: UUID? = nil) {
        healthTabID = rememberAs ?? activeID
        guard settings.settings.netHealthEnabled else {
            healthService.stop()
            return
        }
        let scheme = url?.scheme?.lowercased() ?? ""
        let remembered = healthTabID.flatMap { healthArchive.record(for: $0) }
        if let host, !host.isEmpty, scheme == "http" || scheme == "https" {
            let matches = remembered?.host.lowercased() == host.lowercased()
                && remembered?.scheme.lowercased() == scheme
            if matches, let remembered {
                healthBadge.snapshot = labeledHealth(remembered)
                healthPanel?.apply(remembered)
            }
            healthService.start(host: host, scheme: scheme, restoring: matches ? remembered : nil)
        } else {
            healthService.stop()
        }
    }

    /// VoiceOver hears which pane the badge is describing. The stored snapshot stays unchanged.
    private func labeledHealth(_ snapshot: NetworkHealthSnapshot) -> NetworkHealthSnapshot {
        guard let id = activeID, tiles.isSplitVisible(activeID: id), let layout = tiles.layout else {
            return snapshot
        }
        let suffix = ", \(layout.spokenPlace(of: id))"
        var copy = snapshot
        if !copy.accessibilityLabel.hasSuffix(suffix) {
            copy.accessibilityLabel += suffix
        }
        return copy
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
        if popover === blockPopover {
            blockBadge.extraAccessibilityChild = nil
            blockPopoverController.resetTransient()
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
        if let previous = activeID, previous != id {
            previousActiveID = previous
            if settings.settings.netHealthEnabled {
                healthArchive.remember(healthService.currentSnapshot, for: previous)
            }
        }
        activeID = id
        embedActiveSurface()
        presentActiveTabForBench()
        if switching {
            BenchMarks.emit("tab-switch-completed")
        }
        if let tab = pageTab() {
            feedHealth(host: tab.displayedURL?.host, url: tab.displayedURL, rememberAs: tab.id)
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
        tiles.canvas.layoutSubtreeIfNeeded()
        tiles.canvas.displayIfNeeded()
        window?.displayIfNeeded()
    }

    private func embedActiveSurface() {
        if let id = activeID, tiles.isSplitVisible(activeID: id) {
            showSplit(focus: id)
            return
        }
        tiles.release()
        rehomeSharedPages()
        embedSoloSurface()
    }

    private func embedSoloSurface() {
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
        if let tools = activeDevToolsTab() {
            tools.container.alphaValue = 1
            embed(tools.container, in: webContainer)
            tools.attachAndShowIfNeeded()
            return
        }
        embedActiveWebView()
    }

    private func embed(_ view: NSView, in host: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        // Re-adding a view that is already here removes it first and flashes WKWebView.
        if !HostedViewPlacement.shouldMove(isChildOfTarget: view.superview === host) { return }
        for subview in host.subviews {
            subview.removeFromSuperview()
        }
        view.alphaValue = 1
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
        if !HostedViewPlacement.shouldMove(isChildOfTarget: webView.superview === webContainer) { return }
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
        if isSyncingBars { return }
        isSyncingBars = true
        defer { isSyncingBars = false }
        ensureVisibleSelection()
        if progressOnly {
            if let tools = activeDevToolsTab() {
                let source = webTab(id: tools.sourceID)
                let loading = source?.surface == .web && source?.isLoading == true && (source?.estimatedProgress ?? 1) < 1
                frameBar.showsProgress = loading
                frameBar.fraction = loading ? (source?.estimatedProgress ?? 0) : 0
                return
            }
            guard activeTerminalTab == nil, let tab = activeTab else { return }
            let loading = tab.surface == .web && tab.isLoading && tab.estimatedProgress < 1
            frameBar.showsProgress = loading
            frameBar.fraction = loading ? tab.estimatedProgress : 0
            return
        }
        alignStripToTiles()
        if let tools = activeDevToolsTab() {
            syncDevToolsBars(tools)
            return
        }
        setLinkedChip(visible: false, title: "", url: nil)
        if let terminal = activeTerminalTab {
            syncTerminalBars(terminal)
            return
        }
        guard let tab = activeTab else {
            syncSplitChrome()
            return
        }
        let loading = tab.surface == .web && tab.isLoading && tab.estimatedProgress < 1
        frameBar.showsProgress = loading
        frameBar.fraction = loading ? tab.estimatedProgress : 0
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
        syncBlockBadgeForFocusedPane()
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
        applyTileVisibility()
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
        syncBlockBadgeForFocusedPane()
        window?.title = "\(terminal.name) — \(AppInfo.displayName)"
        feedHealth(host: nil, url: nil)
        refreshAppearanceProbe()
        tabRegion.update(items: stripItems(selectedID: terminal.id))
        terminalHost.isHidden = false
        terminalHost.needsDisplay = true
        webContainer.isHidden = true
        bookmarksPage.isHidden = true
        newTabPage.isHidden = true
        applyTileVisibility()
    }

    private func stripItems(selectedID: UUID) -> [TabStripItem] {
        let members = TileStripGroup.memberIDs(
            savedSplitTabIDs: tiles.tabIDs(),
            splitExists: tiles.hasSavedSplit
        )
        let glyph = members.isEmpty ? nil : stripGlyph()
        let count = members.count
        let rows = visibleSession().map { item in
            let grouped = members.contains(item.id)
            switch item {
            case .web(let tab):
                return tabItem(
                    for: tab,
                    selected: tab.id == selectedID,
                    groupMember: grouped,
                    splitGlyph: grouped ? glyph : nil,
                    memberCount: grouped ? count : 0
                )
            case .terminal(let tab):
                return TabStripItem(
                    id: tab.id,
                    title: tab.command,
                    badgeLetter: "",
                    badgeHex: "",
                    favicon: nil,
                    selected: tab.id == selectedID,
                    groupMember: grouped,
                    splitGlyph: grouped ? glyph : nil,
                    memberCount: grouped ? count : 0,
                    kind: .terminal,
                    glyph: .terminal,
                    accessibilityLabel: "Terminal tab",
                    accessibilityValue: tab.command,
                    accessibilityHelp: tab.name + "\n" + tab.command
                )
            case .devtools(let tab):
                return TabStripItem(
                    id: tab.id,
                    title: tab.displayTitle,
                    badgeLetter: "",
                    badgeHex: "",
                    favicon: nil,
                    selected: tab.id == selectedID,
                    groupMember: grouped,
                    splitGlyph: grouped ? glyph : nil,
                    memberCount: grouped ? count : 0,
                    kind: .devtools,
                    titlePrefix: "DevTools:",
                    pageTitle: tab.pageTitle,
                    partnerID: tab.sourceID,
                    devtoolsTile: true,
                    accessibilityLabel: tab.accessibilityLabel
                )
            }
        }
        return linkingDevToolsPartners(rows)
    }

    private func stripGlyph() -> IconGlyph? {
        switch tiles.layout?.arrangement?.stripGlyph {
        case .twoColumns: return .split2
        case .threeColumns: return .split3
        case .grid: return .splitGrid
        case nil: return nil
        }
    }

    private func removeSession(id: UUID) {
        let closingSource = session.contains { item in
            if case .web(let tab) = item { return tab.id == id }
            return false
        }
        if closingSource {
            for controller in browserWindows() where controller !== self {
                controller.closePartnerDevTools(sourceID: id)
            }
        }
        if let tools = devToolsTab(forSource: id) {
            tools.shutdown()
            tools.container.removeFromSuperview()
            session.removeAll { $0.id == tools.id }
            _ = tiles.remove(tabID: tools.id)
            devToolsHiddenAt[id] = nil
            devToolsMemory[id] = nil
        }
        if let parked = suspendedDevTools.removeValue(forKey: id) {
            parked.shutdown()
            parked.container.removeFromSuperview()
            devToolsHiddenAt[id] = nil
        }
        guard let index = session.firstIndex(where: { $0.id == id }) else { return }
        if case .web = session[index], mediaPromptTabID == id {
            dismissMediaPrompt(grant: false)
        }
        let closingDevToolsSource = devToolsSourceID(of: session[index])
        switch session[index] {
        case .web(let tab):
            removeStandby(tab.id)
            tab.shutdown()
        case .terminal(let tab):
            tab.shutdown()
        case .devtools(let tab):
            tab.finishRemoval()
        }
        let closingActive = session[index].id == activeID
        let closedID = session[index].id
        session.remove(at: index)
        var preferred = tiles.remove(tabID: closedID)
        if let closingDevToolsSource, session.contains(where: { $0.id == closingDevToolsSource }) {
            preferred = closingDevToolsSource
        }
        if session.isEmpty {
            closeConfirmed = true
            window?.close()
            return
        }
        if closingActive {
            if let preferred, session.contains(where: { $0.id == preferred }),
               settings.settings.tabVisibility.allows(sessionKind(id: preferred)) {
                activateTab(id: preferred, switching: true)
            } else {
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
        }
        syncBars(progressOnly: false)
        noteSessionChange()
        if !session.isEmpty {
            focusPaneContentIfNeeded()
        }
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

    /// Shell, working directory, and command are shown. The stored hash stays the command
    /// alone so an older bookmark file still matches. Cancel does not start a process.
    private func confirmRun(_ terminal: TerminalTab) {
        let alert = NSAlert()
        alert.messageText = "Run this command?"
        alert.informativeText = TerminalLaunch.confirmationText(
            command: terminal.command,
            shell: terminal.shell,
            workingDirectory: terminal.workingDirectory
        )
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

    private func tabItem(
        for tab: BrowserTab,
        selected: Bool,
        groupMember: Bool,
        splitGlyph: IconGlyph?,
        memberCount: Int
    ) -> TabStripItem {
        switch tab.surface {
        case .newTab:
            return TabStripItem(
                id: tab.id,
                title: "New Tab",
                badgeLetter: "+",
                badgeHex: SiteBadge.newTabHex,
                favicon: nil,
                selected: selected,
                groupMember: groupMember,
                splitGlyph: splitGlyph,
                memberCount: memberCount
            )
        case .bookmarks:
            return TabStripItem(
                id: tab.id,
                title: tab.title,
                badgeLetter: "B",
                badgeHex: SiteBadge.listHex,
                favicon: nil,
                selected: selected,
                groupMember: groupMember,
                splitGlyph: splitGlyph,
                memberCount: memberCount
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
                selected: selected,
                groupMember: groupMember,
                splitGlyph: splitGlyph,
                memberCount: memberCount
            )
        }
    }

    /// The pane to show after a close. A split prefers the layout's next pane; otherwise the strip neighbor.
    private func resolvedCloseTarget(preferred: UUID?, index: Int) -> UUID {
        if let preferred, session.contains(where: { $0.id == preferred }) {
            return preferred
        }
        let next = min(index, session.count - 1)
        return session[next].id
    }

    private func sessionKind(id: UUID) -> TabKind {
        session.first(where: { $0.id == id })?.kind ?? .web
    }

    private func showSplit(focus id: UUID) {
        tiles.focus(id)
        webContainer.isHidden = true
        terminalHost.isHidden = true
        bookmarksPage.isHidden = true
        newTabPage.isHidden = true
        tiles.present()
        orderSplitSurfaces()
    }

    /// Puts the canvas above another visible page surface without covering the toast or the drop preview.
    /// Hidden siblings do not occlude, so they are not a reason to reparent.
    private func orderSplitSurfaces() {
        let canvas = tiles.canvas
        guard let host = canvas.superview,
              let index = host.subviews.firstIndex(where: { $0 === canvas }) else { return }
        let covers = host.subviews[(index + 1)...].contains { view in
            if view === splitToast { return false }
            if let preview = dragPreview, view === preview { return false }
            if view.isHidden || view.alphaValue < 0.01 { return false }
            return true
        }
        guard covers else { return }
        if splitToast.superview === host {
            host.addSubview(canvas, positioned: .below, relativeTo: splitToast)
        } else if HostedViewPlacement.shouldRaise(
            isChildOfTarget: true,
            isFrontmost: host.subviews.last === canvas
        ) {
            host.addSubview(canvas)
        }
    }

    /// Keeps the saved layout while a non-member tab is showing, and puts shared pages back on the page host.
    private func applyTileVisibility() {
        let ids = Set(session.map(\.id))
        panePages = panePages.filter { ids.contains($0.key) }
        paneBookmarkPages = paneBookmarkPages.filter { ids.contains($0.key) }
        styledToken = styledToken.filter { ids.contains($0.key) }
        healthArchive.prune(keeping: ids)
        tiles.prune(keeping: ids)
        tiles.stampKinds { id in
            guard session.contains(where: { $0.id == id }) else { return nil }
            return sessionKind(id: id)
        }
        updateTileWindowMinSize()
        guard let id = activeID, tiles.isSplitVisible(activeID: id) else {
            let wasShowing = !tiles.canvas.isHidden
            tiles.release()
            rehomeSharedPages()
            if wasShowing {
                embedSoloSurface()
            }
            parkInactiveDevTools()
            attachVisibleDevTools()
            if tiles.canvas.consumeStructureChange() {
                focusPaneContentIfNeeded()
            }
            syncSplitChrome()
            return
        }
        showSplit(focus: id)
        parkInactiveDevTools()
        attachVisibleDevTools()
        reloadVisiblePanePages()
        if tiles.canvas.consumeStructureChange() {
            focusPaneContentIfNeeded()
        }
        syncSplitChrome()
    }

    private func rehomeSharedPages() {
        adoptInPageHost(bookmarksPage)
        adoptInPageHost(newTabPage)
    }

    private func adoptInPageHost(_ view: NSView) {
        guard view.superview !== pageHost else { return }
        view.removeFromSuperview()
        pageHost.addSubview(view)
        pinToEdges(view)
    }

    private func tileContent(id: UUID, focused _: Bool) -> TilePanePresentation? {
        guard let item = session.first(where: { $0.id == id }) else { return nil }
        switch item {
        case .terminal(let tab):
            let size = CGFloat(settings.settings.terminalFontSize)
            if tab.fontSize != size || styledToken[id] != tileStyleToken {
                tab.fontSize = size
                tab.applyColors()
                styledToken[id] = tileStyleToken
            }
            let host = TilePaneHost(view: tab.view, title: tab.name, focus: tab.view, kind: .terminal)
            return TilePanePresentation(
                content: host,
                insets: NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22),
                fill: .terminal
            )
        case .web(let tab):
            switch tab.surface {
            case .web:
                if styledToken[id] != tileStyleToken {
                    tab.webView.underPageBackgroundColor = Theme.page
                    styledToken[id] = tileStyleToken
                }
                let host = TilePaneHost(view: tab.webView, title: tab.title, focus: tab.webView, kind: .web)
                return TilePanePresentation(content: host, insets: NSEdgeInsets(), fill: .page)
            case .newTab:
                let page = panePage(for: id)
                page.isHidden = false
                let host = TilePaneHost(view: page, title: "New Tab", focus: page.inputField, kind: .web)
                return TilePanePresentation(content: host, insets: NSEdgeInsets(), fill: .page)
            case .bookmarks:
                let page = paneBookmarks(for: id)
                page.isHidden = false
                let host = TilePaneHost(view: page, title: tab.title, focus: page, kind: .web)
                return TilePanePresentation(content: host, insets: NSEdgeInsets(), fill: .page)
            }
        case .devtools(let tab):
            tab.container.alphaValue = 1
            let host = TilePaneHost(
                view: tab.container,
                title: tab.accessibilityName,
                focus: tab.focusTarget,
                kind: .devtools
            )
            return TilePanePresentation(content: host, insets: NSEdgeInsets(), fill: .page, pill: .devtools)
        }
    }

    private func panePage(for id: UUID) -> NewTabPageView {
        if let page = panePages[id] { return page }
        let page = NewTabPageView(store: bookmarks)
        page.translatesAutoresizingMaskIntoConstraints = false
        page.inputField.setAccessibilityIdentifier("wyvern.newtab.pane.\(id.uuidString)")
        page.onSubmit = { [weak self] text in
            guard let self else { return }
            self.activateTab(id: id, switching: false)
            self.commit(text: text)
        }
        page.onOpen = { [weak self] bookmark in
            guard let self else { return }
            self.activateTab(id: id, switching: false)
            self.openBookmark(bookmark)
        }
        panePages[id] = page
        return page
    }

    private func paneBookmarks(for id: UUID) -> BookmarksPageView {
        if let page = paneBookmarkPages[id] { return page }
        let page = BookmarksPageView(store: bookmarks)
        page.translatesAutoresizingMaskIntoConstraints = false
        page.onOpen = { [weak self] bookmark in
            guard let self else { return }
            self.activateTab(id: id, switching: false)
            self.openBookmark(bookmark)
        }
        page.onImport = { [weak self] in
            self?.activateTab(id: id, switching: false)
            self?.presentBookmarkImport()
        }
        paneBookmarkPages[id] = page
        return page
    }

    private func reloadVisiblePanePages() {
        for id in tiles.tabIDs() {
            panePages[id]?.reload()
            paneBookmarkPages[id]?.reload()
        }
    }

    private func focusPaneContent() {
        guard let window else { return }
        if let id = activeID, tiles.isSplitVisible(activeID: id),
           let target = tileContent(id: id, focused: true)?.content?.tileFocusTarget {
            window.makeFirstResponder(target)
            return
        }
        if let terminal = activeTerminalTab {
            window.makeFirstResponder(terminal.view)
            return
        }
        if let tools = activeDevToolsTab() {
            window.makeFirstResponder(tools.focusTarget)
            return
        }
        guard let tab = activeTab else { return }
        switch tab.surface {
        case .web:
            window.makeFirstResponder(tab.webView)
        case .newTab:
            window.makeFirstResponder(newTabPage.inputField)
        case .bookmarks:
            window.makeFirstResponder(bookmarksPage)
        }
    }

    /// Restores keystrokes to the focused pane. An in-progress address-bar edit keeps the field.
    private func focusPaneContentIfNeeded() {
        guard !addressField.isEditingURL else { return }
        focusPaneContent()
    }

    private func responderIsInsideCanvas() -> Bool {
        guard let view = window?.firstResponder as? NSView else { return false }
        var current: NSView? = view
        while let node = current {
            if node === tiles.canvas { return true }
            current = node.superview
        }
        return false
    }

    private func tabContextMenu(for id: UUID) -> NSMenu {
        if sessionKind(id: id) == .devtools {
            return devToolsContextMenu(for: id)
        }
        let menu = NSMenu()
        let withCurrent = menuItem("Split with Current Tab", action: #selector(splitWithCurrentTab(_:)), id: id)
        let right = menuItem("Split Right", action: #selector(splitRight(_:)), id: id)
        let below = menuItem("Split Below", action: #selector(splitDown(_:)), id: id)
        menu.addItem(withCurrent)
        menu.addItem(right)
        menu.addItem(below)
        if tiles.hasSavedSplit {
            let add = menuItem("Add to Split", action: #selector(addToSplit(_:)), id: id)
            if tiles.tabIDs().count >= TileArrangement.maximumPanes {
                add.isEnabled = false
                add.toolTip = "Split View holds up to 4 tabs"
            } else if tiles.layout?.contains(id) == true {
                add.isEnabled = false
            }
            menu.addItem(add)
            if tiles.layout?.contains(id) == true {
                menu.addItem(menuItem("Remove from Split", action: #selector(removeFromSplit(_:)), id: id))
            }
        }
        return menu
    }

    private func menuItem(_ title: String, action: Selector, id: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    @objc func splitRight(_ sender: Any?) {
        performSplit(axis: .horizontal, sender: sender)
    }

    @objc func splitDown(_ sender: Any?) {
        performSplit(axis: .vertical, sender: sender)
    }

    @objc func closePane(_ sender: Any?) {
        guard tiles.isSplitVisible(activeID: activeID), let id = activeID else { return }
        closeTab(id: id)
    }

    @objc func focusNextPane(_ sender: Any?) {
        focusAdjacentPane(forward: true)
    }

    @objc func focusPreviousPane(_ sender: Any?) {
        focusAdjacentPane(forward: false)
    }

    @objc func equalizePanes(_ sender: Any?) {
        guard tiles.isSplitVisible(activeID: activeID) else { return }
        let inside = responderIsInsideCanvas()
        tiles.equalizeAll()
        tiles.present()
        if inside {
            focusPaneContentIfNeeded()
        }
    }

    @objc func unsplit(_ sender: Any?) {
        performUnsplit()
    }

    @objc func focusPaneLeft(_ sender: Any?) { moveFocus(toward: .left) }
    @objc func focusPaneRight(_ sender: Any?) { moveFocus(toward: .right) }
    @objc func focusPaneUp(_ sender: Any?) { moveFocus(toward: .up) }
    @objc func focusPaneDown(_ sender: Any?) { moveFocus(toward: .down) }
    @objc func swapPaneLeft(_ sender: Any?) { swapFocus(toward: .left) }
    @objc func swapPaneRight(_ sender: Any?) { swapFocus(toward: .right) }

    @objc func applyLayout(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let arrangement = TileArrangement(rawValue: raw) else { return }
        applyArrangement(arrangement)
    }

    @objc func splitWithCurrentTab(_ sender: Any?) {
        guard let clicked = (sender as? NSMenuItem)?.representedObject as? UUID,
              session.contains(where: { $0.id == clicked }) else { return }
        guard let current = activeID else { return }
        if clicked == current {
            performSplit(axis: .horizontal, sender: nil)
            return
        }
        if let layout = tiles.layout, layout.isSplit, !layout.contains(current), !layout.contains(clicked) {
            return
        }
        guard tiles.place(tabID: clicked, beside: current, edge: .right, kind: sessionKind(id: clicked)) else { return }
        activateTab(id: clicked, switching: false)
        syncBars(progressOnly: false)
        focusPaneContentIfNeeded()
    }

    @objc func addToSplit(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        guard let layout = tiles.layout, layout.isSplit, !layout.contains(id) else { return }
        guard layout.tabIDs().count < TileArrangement.maximumPanes else { return }
        let anchor = layout.focusedTabID
        guard tiles.place(tabID: id, beside: anchor, edge: .right, kind: sessionKind(id: id)) else { return }
        activateTab(id: id, switching: false)
        syncBars(progressOnly: false)
        focusPaneContentIfNeeded()
    }

    @objc func removeFromSplit(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        let next = tiles.remove(tabID: id)
        if activeID == id, let next, session.contains(where: { $0.id == next }) {
            activateTab(id: next, switching: true)
        } else if activeID == id {
            embedActiveSurface()
        }
        syncBars(progressOnly: false)
        focusPaneContentIfNeeded()
    }

    /// Rolls back tabs created for a split that could not be built, and refreshes the strip and page.
    private func discardFailedSplitTabs(_ tabs: [BrowserTab], restore previous: UUID?) {
        let ids = Set(tabs.map(\.id))
        for tab in tabs {
            tab.shutdown()
            panePages[tab.id] = nil
            paneBookmarkPages[tab.id] = nil
        }
        session.removeAll { ids.contains($0.id) }
        if let previous, session.contains(where: { $0.id == previous }) {
            activeID = previous
        } else if let current = activeID, session.contains(where: { $0.id == current }) {
            // The selection still names a live tab.
        } else {
            activeID = session.first?.id
        }
        embedActiveSurface()
        syncBars(progressOnly: false)
        noteSessionChange()
    }

    private func performSplit(axis: TileAxis, sender: Any?) {
        let anchor = (sender as? NSMenuItem)?.representedObject as? UUID ?? activeID
        guard let anchor, session.contains(where: { $0.id == anchor }) else { return }
        if let layout = tiles.layout, layout.isSplit, !layout.contains(anchor) {
            guard layout.tabIDs().count < TileArrangement.maximumPanes else { return }
            let beside = layout.focusedTabID
            let edge: TileEdge = axis == .horizontal ? .right : .down
            guard tiles.place(tabID: anchor, beside: beside, edge: edge, kind: sessionKind(id: anchor)) else { return }
            activateTab(id: anchor, switching: false)
            syncBars(progressOnly: false)
            focusPaneContentIfNeeded()
            return
        }
        let edge: TileEdge = axis == .horizontal ? .right : .down
        if let layout = tiles.layout, layout.isSplit,
           layout.expanded(adding: UUID(), beside: anchor, edge: edge) == nil {
            return
        }
        let previous = activeID
        let tab = addTab(deferPresentation: true)
        guard tiles.insert(newTab: tab.id, beside: anchor, axis: axis) else {
            discardFailedSplitTabs([tab], restore: previous)
            return
        }
        tab.show(.newTab)
        activateTab(id: tab.id, switching: false)
        syncBars(progressOnly: false)
        presentActiveTabForBench()
        BenchMarks.emit("tab-ready")
        focusLocationField()
    }

    private func focusAdjacentPane(forward: Bool) {
        guard tiles.isSplitVisible(activeID: activeID), let id = tiles.focusAdjacent(forward: forward) else { return }
        let editing = addressField.isEditingURL
        activateTab(id: id, switching: true)
        syncBars(progressOnly: false)
        if !editing {
            focusPaneContent()
        }
    }

    private func moveFocus(toward edge: TileEdge) {
        guard tiles.isSplitVisible(activeID: activeID), let id = tiles.focus(toward: edge) else { return }
        let editing = addressField.isEditingURL
        activateTab(id: id, switching: true)
        syncBars(progressOnly: false)
        if !editing {
            focusPaneContent()
        }
    }

    private func swapFocus(toward edge: TileEdge) {
        guard tiles.isSplitVisible(activeID: activeID), tiles.swap(toward: edge) else { return }
        tiles.present()
        syncBars(progressOnly: false)
    }

    private func performUnsplit() {
        guard tiles.hasSavedSplit, let focus = activeID else { return }
        let order = TileStripOrder.placingMembers(
            session: session.map(\.id),
            focused: focus,
            membersInOrder: tiles.tabIDs()
        )
        _ = applySessionOrder(order)
        tiles.unsplit()
        embedActiveSurface()
        syncBars(progressOnly: false)
        focusPaneContentIfNeeded()
    }

    private func splitViewClicked() {
        if tiles.isSplitVisible(activeID: activeID) {
            performUnsplit()
            return
        }
        guard let current = activeID else {
            _ = addTab()
            return
        }
        if tiles.hasSavedSplit {
            guard tiles.tabIDs().count < TileArrangement.maximumPanes else { return }
            let anchor = tiles.layout?.focusedTabID ?? current
            guard tiles.place(tabID: current, beside: anchor, edge: .right, kind: sessionKind(id: current)) else { return }
            activateTab(id: current, switching: false)
            syncBars(progressOnly: false)
            focusPaneContentIfNeeded()
            return
        }
        if let other = recentOtherTab(besides: current) {
            guard tiles.place(tabID: other, beside: current, edge: .right, kind: sessionKind(id: other)) else { return }
            activateTab(id: current, switching: false)
            syncBars(progressOnly: false)
            focusPaneContentIfNeeded()
            return
        }
        performSplit(axis: .horizontal, sender: nil)
    }

    private func showLayoutPopover() {
        layoutPicker.selected = tiles.layout?.arrangement
        layoutPopover.show(relativeTo: splitButton.bounds, of: splitButton, preferredEdge: .maxY)
    }

    private func applyArrangement(_ arrangement: TileArrangement) {
        guard let focus = activeID else { return }
        if let layout = tiles.layout, layout.isSplit {
            let deficit = max(0, arrangement.paneCount - layout.tabIDs().count)
            if deficit > 0 {
                let probe = (0..<deficit).map { _ in UUID() }
                guard layout.converted(to: arrangement, filling: probe) != nil else { return }
            }
            var filling: [UUID] = []
            var created: [BrowserTab] = []
            for _ in 0..<deficit {
                let tab = addTab(deferPresentation: true)
                tab.show(.newTab)
                filling.append(tab.id)
                created.append(tab)
            }
            guard let next = layout.converted(to: arrangement, filling: filling) else {
                discardFailedSplitTabs(created, restore: focus)
                return
            }
            tiles.replaceLayout(next)
            activateTab(id: next.focusedTabID, switching: false)
            syncBars(progressOnly: false)
            focusPaneContentIfNeeded()
            return
        }
        var ids = [focus]
        if let other = recentOtherTab(besides: focus) {
            ids.append(other)
        }
        guard Set(ids).count == ids.count else { return }
        var created: [BrowserTab] = []
        while ids.count < arrangement.paneCount {
            let tab = addTab(deferPresentation: true)
            tab.show(.newTab)
            ids.append(tab.id)
            created.append(tab)
        }
        let kinds = ids.map { sessionKind(id: $0) }
        guard let next = TileLayout.arranged(arrangement, tabs: ids, kinds: kinds, focused: focus) else {
            discardFailedSplitTabs(created, restore: focus)
            return
        }
        tiles.replaceLayout(next)
        activateTab(id: focus, switching: false)
        syncBars(progressOnly: false)
        focusPaneContentIfNeeded()
    }

    private func alignStripToTiles() {
        var changed = false
        if let id = activeID, tiles.isSplitVisible(activeID: id) {
            let order = TileStripOrder.placingMembers(
                session: session.map(\.id),
                focused: id,
                membersInOrder: tiles.tabIDs()
            )
            if applySessionOrder(order) {
                changed = true
            }
        }
        if pinDevToolsOrder() {
            changed = true
        }
        if changed {
            noteSessionChange()
        }
    }

    private func applySessionOrder(_ order: [UUID]) -> Bool {
        let current = session.map(\.id)
        guard current != order else { return false }
        var byID: [UUID: SessionTab] = [:]
        for item in session {
            byID[item.id] = item
        }
        let next = order.compactMap { byID[$0] }
        guard next.count == session.count else { return false }
        session = next
        return true
    }

    private func recentOtherTab(besides id: UUID) -> UUID? {
        if let previous = previousActiveID, previous != id, session.contains(where: { $0.id == previous }) {
            return previous
        }
        guard let index = session.firstIndex(where: { $0.id == id }) else { return nil }
        if index > 0 { return session[index - 1].id }
        if index + 1 < session.count { return session[index + 1].id }
        return nil
    }

    private func updateTileWindowMinSize() {
        guard let window else { return }
        let count = tiles.layout?.tabIDs().count ?? 0
        let minWidth = CGFloat(TileDisplay.requiredContentMinWidth(
            paneCount: count,
            splitVisible: tiles.isSplitVisible(activeID: activeID),
            base: 980,
            paneMinWidth: Double(MonoMetrics.paneMinWidth),
            divider: Double(MonoMetrics.dividerHit)
        ))
        if let applied = appliedTileContentMinWidth, abs(applied - minWidth) < 0.5 {
            return
        }
        appliedTileContentMinWidth = minWidth
        if abs(window.contentMinSize.width - minWidth) < 0.5,
           abs(window.minSize.width - minWidth) < 0.5 {
            return
        }
        let contentHeight = window.contentMinSize.height
        let frameHeight = window.minSize.height
        window.contentMinSize = NSSize(width: minWidth, height: contentHeight > 1 ? contentHeight : 640)
        window.minSize = NSSize(width: minWidth, height: frameHeight > 1 ? frameHeight : 640)
    }

    private func syncSplitChrome() {
        let showing = tiles.isSplitVisible(activeID: activeID)
        splitButton.toolTip = showing ? "Unsplit" : "Split View"
        splitButton.setAccessibilityLabel(showing ? "Unsplit" : "Split View")
        splitButton.tint = showing ? Theme.accent : Theme.mute
        splitButton.fill = .clear
        // Shortcuts and layout checkmarks live on the shared menu. A background window must not rewrite them.
        guard window?.isKeyWindow == true else { return }
        if let main = NSApp.mainMenu {
            walkMenu(main) { item in
                if item.action == #selector(splitRight(_:)) {
                    item.keyEquivalent = showing ? "" : "\\"
                    item.keyEquivalentModifierMask = [.command, .control]
                } else if item.action == #selector(unsplit(_:)) {
                    item.keyEquivalent = showing ? "\\" : ""
                    item.keyEquivalentModifierMask = [.command, .control]
                } else if item.action == #selector(applyLayout(_:)),
                          let raw = item.representedObject as? String,
                          let arrangement = TileArrangement(rawValue: raw) {
                    item.state = tiles.layout?.arrangement == arrangement ? .on : .off
                }
            }
        }
        announcePaneFocusIfNeeded()
    }

    private func walkMenu(_ menu: NSMenu, visit: (NSMenuItem) -> Void) {
        for item in menu.items {
            visit(item)
            if let submenu = item.submenu {
                walkMenu(submenu, visit: visit)
            }
        }
    }

    private func announcePaneFocusIfNeeded() {
        guard let id = activeID, tiles.isSplitVisible(activeID: id), let layout = tiles.layout else {
            announcedPaneID = nil
            return
        }
        guard announcedPaneID != id else { return }
        announcedPaneID = id
        let place = layout.spokenPlace(of: id)
        let message = "Focused \(place), \(announcementName(id: id))"
        NSAccessibility.post(element: tiles.canvas, notification: .announcementRequested, userInfo: [
            .announcement: message as NSString
        ])
    }

    private func announcementName(id: UUID) -> String {
        guard let item = session.first(where: { $0.id == id }) else { return "pane" }
        switch item {
        case .web(let tab):
            if let host = tab.displayedURL?.host, !host.isEmpty {
                return host
            }
            return tab.surface == .newTab ? "New Tab" : tab.title
        case .terminal(let tab):
            return tab.name
        case .devtools(let tab):
            return tab.accessibilityName
        }
    }

    private struct TileDropTarget {
        var anchor: UUID
        var edge: TileEdge
        var previewRect: NSRect
        var caption: String
    }

    private func updateTileDrag(tabID: UUID, screenPoint: NSPoint) {
        if tileDragCancelled { return }
        installTileDragMonitor()
        guard let target = tileDropTarget(at: screenPoint, dragging: tabID), tileDropCanApply(tabID: tabID, target: target) else {
            hideDropPreview()
            return
        }
        let key = "\(tabID.uuidString)|\(target.anchor.uuidString)|\(target.edge.rawValue)"
        pendingPreviewRect = target.previewRect
        pendingPreviewCaption = target.caption
        if key == dragPreviewKey {
            dragPreview?.frame = target.previewRect
            dragPreview?.caption = target.caption
            return
        }
        hideDropPreview()
        dragPreviewKey = key
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced {
            showDropPreview(rect: target.previewRect, caption: target.caption, animated: false)
            return
        }
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dragPreviewKey == key else { return }
                self.showDropPreview(rect: self.pendingPreviewRect, caption: self.pendingPreviewCaption, animated: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragPreviewTimer = timer
    }

    private func installTileDragMonitor() {
        guard tileDragMonitor == nil else { return }
        tileDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.keyCode == 53 {
                    self.tileDragCancelled = true
                    self.tabRegion.cancelTabDrags()
                    self.endTileDragChrome()
                    return nil
                }
                return event
            }
        }
    }

    private func endTileDragChrome() {
        hideDropPreview()
        if let monitor = tileDragMonitor {
            NSEvent.removeMonitor(monitor)
            tileDragMonitor = nil
        }
    }

    private func hideDropPreview() {
        dragPreviewTimer?.invalidate()
        dragPreviewTimer = nil
        dragPreviewKey = nil
        dragPreview?.isHidden = true
        dragPreview?.removeFromSuperview()
    }

    private func showDropPreview(rect: NSRect, caption: String = "", animated: Bool) {
        let preview = dragPreview ?? TileDropPreview(frame: rect)
        dragPreview = preview
        preview.caption = caption
        preview.frame = rect
        if preview.superview !== pageHost {
            pageHost.addSubview(preview, positioned: .above, relativeTo: tiles.canvas)
        }
        preview.isHidden = false
        if animated {
            preview.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                preview.animator().alphaValue = 1
            }
        } else {
            preview.alphaValue = 1
        }
    }

    private func pageContains(_ screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let local = pageHost.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return pageHost.bounds.contains(local)
    }

    private func tileDropTarget(at screenPoint: NSPoint, dragging tabID: UUID) -> TileDropTarget? {
        guard let window else { return nil }
        let local = pageHost.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard pageHost.bounds.contains(local) else { return nil }
        let allowTop = sessionKind(id: tabID) == .devtools
        if tiles.isSplitVisible(activeID: activeID) {
            for (id, frame) in tiles.canvas.paneFrames() {
                let inPage = tiles.canvas.convert(frame, to: pageHost)
                if inPage.contains(local), let edge = dropEdge(in: inPage, point: local, allowTop: allowTop) {
                    let caption = devToolsDropCaption(dragging: tabID, anchor: id, edge: edge)
                    return TileDropTarget(
                        anchor: id,
                        edge: edge,
                        previewRect: dropPreviewRect(in: inPage, edge: edge),
                        caption: caption
                    )
                }
            }
            return nil
        }
        // A hidden saved split is left in place. Previewing an edge here would anchor on the
        // active tab, which is not a member, and the drop would be ignored.
        if tiles.hasSavedSplit {
            return nil
        }
        guard let anchor = activeID, let edge = dropEdge(in: pageHost.bounds, point: local, allowTop: allowTop) else { return nil }
        return TileDropTarget(
            anchor: anchor,
            edge: edge,
            previewRect: dropPreviewRect(in: pageHost.bounds, edge: edge),
            caption: devToolsDropCaption(dragging: tabID, anchor: anchor, edge: edge)
        )
    }


    /// False when the drop would be ignored: a hidden saved split, or an edge 1+2 cannot grow.
    private func tileDropCanApply(tabID: UUID, target: TileDropTarget) -> Bool {
        guard let layout = tiles.layout, layout.isSplit else { return true }
        guard layout.contains(target.anchor) else { return false }
        if tabID != target.anchor, layout.contains(tabID) {
            return true
        }
        let incoming: UUID
        if tabID == target.anchor {
            if let other = recentOtherTab(besides: tabID), !layout.contains(other) {
                incoming = other
            } else if recentOtherTab(besides: tabID) == nil {
                incoming = UUID()
            } else {
                return true
            }
        } else {
            incoming = tabID
        }
        return layout.expanded(adding: incoming, beside: target.anchor, edge: target.edge) != nil
    }

    private func dropEdge(in rect: NSRect, point: NSPoint, allowTop: Bool = false) -> TileEdge? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        if point.x <= rect.minX + rect.width * 0.25 { return .left }
        if point.x >= rect.maxX - rect.width * 0.25 { return .right }
        if allowTop, point.y >= rect.maxY - rect.height * 0.25 { return .up }
        if point.y <= rect.minY + rect.height * 0.25 { return .down }
        return nil
    }

    private func dropPreviewRect(in rect: NSRect, edge: TileEdge) -> NSRect {
        switch edge {
        case .left:
            return NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right:
            return NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .down:
            return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .up:
            return NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }

    private func performTileDrop(tabID: UUID, target: TileDropTarget) {
        if sessionKind(id: tabID) == .devtools {
            let source = devToolsTab(id: tabID)?.sourceID
            let onPage = target.anchor == source || target.anchor == tabID
            if onPage, let source {
                let side = DevToolsSide(edge: target.edge)
                guard tiles.placeDevTools(
                    devtools: tabID,
                    beside: source,
                    side: side,
                    pageFraction: DevToolsPlacement.pageFraction
                ) else { return }
                rememberDevToolsPair(source: source, devtools: tabID)
                announcedPaneID = tabID
                activateTab(id: tabID, switching: false)
                syncBars(progressOnly: false)
                announce(side.moveAnnouncement)
                focusPaneContentIfNeeded()
                return
            }
        }
        let axis: TileAxis = (target.edge == .up || target.edge == .down) ? .vertical : .horizontal
        if tabID == target.anchor {
            if let other = recentOtherTab(besides: tabID) {
                guard tiles.place(tabID: other, beside: tabID, edge: target.edge, kind: sessionKind(id: other)) else { return }
                activateTab(id: tabID, switching: false)
            } else {
                if let layout = tiles.layout, layout.isSplit {
                    guard layout.contains(tabID) else { return }
                    guard layout.expanded(adding: UUID(), beside: tabID, edge: target.edge) != nil else { return }
                }
                let previous = activeID
                let tab = addTab(deferPresentation: true)
                guard tiles.insert(newTab: tab.id, beside: tabID, axis: axis) else {
                    discardFailedSplitTabs([tab], restore: previous)
                    return
                }
                tab.show(.newTab)
                activateTab(id: tab.id, switching: false)
                syncBars(progressOnly: false)
                focusLocationField()
                return
            }
        } else {
            guard tiles.place(tabID: tabID, beside: target.anchor, edge: target.edge, kind: sessionKind(id: tabID)) else { return }
            activateTab(id: tabID, switching: false)
        }
        syncBars(progressOnly: false)
        focusPaneContentIfNeeded()
    }

    private func removeFromSplitIfDroppedOutside(tabID: UUID, visibleIndex: Int) {
        guard let layout = tiles.layout, layout.contains(tabID) else { return }
        let members = Set(layout.tabIDs())
        let visible = visibleSession()
        let indexes = visible.enumerated().compactMap { members.contains($0.element.id) ? $0.offset : nil }
        guard let first = indexes.min(), let last = indexes.max() else { return }
        if visibleIndex < first || visibleIndex > last + 1 {
            _ = tiles.remove(tabID: tabID)
        }
    }

    private func commit(text: String) {
        if activeDevToolsTab() != nil { return }
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
        // Name the tab's top-level page. The stored choice stays on the requester origin.
        let named = MediaPermissionPolicy.sheetOrigin(
            topLevelURL: tab.webView.url ?? tab.displayedURL,
            requesterOrigin: origin
        )
        let prompt = MediaPermissionPromptController(origin: named, kind: kind)
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
        close?.setAccessibilityIdentifier("wyvern.traffic.close")
        miniaturize?.setAccessibilityIdentifier("wyvern.traffic.min")
        zoom?.setAccessibilityIdentifier("wyvern.traffic.zoom")
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
        let line = "WYVERN_WINDOW_ID=\(number)\n"
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

    private func applyBlockListChange(_ note: Notification) {
        let rulesChanged = note.userInfo?["rulesChanged"] as? Bool ?? false
        if rulesChanged {
            for item in session {
                if case .web(let tab) = item {
                    tab.installCookieRules()
                }
            }
            applyWebPageMetrics()
        }
        if blockPopover.isShown {
            refreshBlockPopover()
        }
        syncBars(progressOnly: false)
    }

    /// Right-side cluster. Kept as a hook for callers that change badge visibility.
    private func syncRightCluster() {
        // The toolbar cluster is an NSStackView with detachesHiddenViews, so hidden badges drop out.
        toolbarCluster.needsLayout = true
    }

    /// The page the blocked-count badge describes.
    /// A visible split uses the focused pane, even when the strip's selected tab is different.
    private enum BlockBadgeSubject {
        case web(BrowserTab)
        case terminal
        case strip(BrowserTab?)
    }

    private func blockBadgeSubject() -> BlockBadgeSubject {
        if tiles.isSplitVisible(activeID: activeID),
           let focus = tiles.layout?.focusedTabID,
           let item = session.first(where: { $0.id == focus }) {
            switch item {
            case .terminal:
                return .terminal
            case .web(let tab):
                return .web(tab)
            case .devtools:
                // A DevTools pane has no page of its own. Hide the badge, like a terminal.
                return .terminal
            }
        }
        if activeTerminalTab != nil {
            return .terminal
        }
        return .strip(activeTab)
    }

    private func syncBlockBadgeForFocusedPane() {
        switch blockBadgeSubject() {
        case .terminal:
            syncBlockBadge(url: nil, count: 0, terminal: true, tab: nil)
        case .web(let tab):
            syncBlockBadge(
                url: tab.displayedURL,
                count: tab.blockedRequestCount,
                terminal: false,
                tab: tab
            )
        case .strip(let tab):
            syncBlockBadge(
                url: tab?.displayedURL,
                count: tab?.blockedRequestCount ?? 0,
                terminal: false,
                tab: tab
            )
        }
    }

    private func reloadBlockBadgeTab() {
        let tab: BrowserTab?
        switch blockBadgeSubject() {
        case .web(let focused):
            tab = focused
        case .strip(let focused):
            tab = focused
        case .terminal:
            tab = nil
        }
        guard let tab, tab.surface == .web else { return }
        tab.webView.reload()
    }

    private func syncBlockBadge(url: URL?, count: Int, terminal: Bool, tab: BrowserTab?) {
        let show = blockBadgeShouldShow(terminal: terminal, tab: tab)
        blockBadge.setAccessibilityElement(show)
        if show == false {
            blockBadge.isHidden = true
            blockWidth?.constant = CGFloat(
                BlockedBadgeVisibility.constraintWidth(visible: false, preferredWidth: 0)
            )
            if blockPopover.isShown {
                blockPopover.performClose(nil)
            }
            syncRightCluster()
            return
        }
        let controller = BlockListController.shared
        let host = BlockListController.displayHost(url)
        let look: BlockedCountBadge.Look
        if controller.blockingEnabled == false {
            look = .disabled
        } else if controller.siteToggleEnabled(host: host), controller.blocksSite(host: host) == false {
            look = .paused
        } else if count <= 0 {
            look = .zero
        } else {
            look = .active
        }
        blockBadge.apply(count: count, host: host, look: look)
        // Width first: detachesHiddenViews reattaches at the current constraint. Zero-width unhide stays collapsed.
        blockWidth?.constant = CGFloat(
            BlockedBadgeVisibility.constraintWidth(
                visible: true,
                preferredWidth: Double(blockBadge.preferredWidth)
            )
        )
        blockBadge.isHidden = false
        if blockPopover.isShown {
            refreshBlockPopover()
        }
        syncRightCluster()
    }

    private func blockBadgeShouldShow(terminal: Bool, tab: BrowserTab?) -> Bool {
        BlockedBadgeVisibility.shouldShow(
            blockingEnabled: BlockListController.shared.blockingEnabled,
            showBlockedCount: BlockListController.shared.showBlockedCount,
            isTerminal: terminal,
            isWebSurface: tab?.surface == .web,
            scheme: tab?.displayedURL?.scheme
        )
    }

    @objc private func blockBadgeTapped() {
        if blockPopover.isShown {
            blockPopover.performClose(nil)
            return
        }
        guard blockBadge.isHidden == false else { return }
        refreshBlockPopover()
        blockPopover.show(relativeTo: blockBadge.bounds, of: blockBadge, preferredEdge: .maxY)
        blockBadge.extraAccessibilityChild = blockPopoverController.view
    }

    private func setFocusedSitePaused(_ paused: Bool) {
        let tab: BrowserTab?
        switch blockBadgeSubject() {
        case .web(let focused):
            tab = focused
        case .strip(let focused):
            tab = focused
        case .terminal:
            tab = nil
        }
        guard let tab else { return }
        let host = BlockListController.displayHost(tab.displayedURL)
        guard let host else {
            refreshBlockPopover()
            return
        }
        BlockListController.shared.setBlocksSite(host: host, blocked: paused == false) { [weak self] ok in
            self?.blockPopoverController.noteUserChange(success: ok)
            self?.refreshBlockPopover()
        }
    }

    private func refreshBlockPopover() {
        let tab: BrowserTab?
        switch blockBadgeSubject() {
        case .web(let focused):
            tab = focused
        case .strip(let focused):
            tab = focused
        case .terminal:
            tab = nil
        }
        let host = BlockListController.displayHost(tab?.displayedURL)
        let controller = BlockListController.shared
        let paused = controller.blockingEnabled
            && controller.siteToggleEnabled(host: host)
            && controller.blocksSite(host: host) == false
        blockPopoverController.apply(
            host: host,
            count: blockedCountForFocusedTab(tab),
            blockingEnabled: controller.blockingEnabled,
            paused: paused,
            canPause: controller.siteToggleEnabled(host: host)
        )
    }

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
        let width = CGFloat(BlockedBadgeVisibility.constraintWidth(
            visible: visible,
            preferredWidth: Double(MonoMetrics.control)
        ))
        // Width first. detachesHiddenViews reattaches at the current constant, so un-hiding at 0 collapses the button.
        if visible {
            downloadsWidth?.constant = width
            downloadsButton.isHidden = false
        } else {
            downloadsButton.isHidden = true
            downloadsWidth?.constant = width
        }
        downloadsButton.tint = DownloadManager.shared.hasActiveDownload ? Theme.accent : Theme.mute
        syncRightCluster()
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

    // MARK: DevTools tab

    private func webTab(id: UUID) -> BrowserTab? {
        for item in session {
            if case .web(let tab) = item, tab.id == id {
                return tab
            }
        }
        return nil
    }

    private func webTabInAnyWindow(id: UUID) -> BrowserTab? {
        if let tab = webTab(id: id) {
            return tab
        }
        for controller in browserWindows() where controller !== self {
            if let tab = controller.webTab(id: id) {
                return tab
            }
        }
        return nil
    }

    private func browserWindows() -> [BrowserWindowController] {
        var seen = Set<ObjectIdentifier>()
        var result: [BrowserWindowController] = []
        for window in NSApp.windows {
            guard let controller = window.windowController as? BrowserWindowController else { continue }
            if seen.insert(ObjectIdentifier(controller)).inserted {
                result.append(controller)
            }
        }
        return result
    }

    private func windowHosting(tab id: UUID) -> BrowserWindowController? {
        if session.contains(where: { $0.id == id }) {
            return self
        }
        return browserWindows().first { $0.session.contains(where: { $0.id == id }) }
    }

    private func activeDevToolsTab() -> DevToolsTab? {
        guard let activeID else { return nil }
        return devToolsTab(id: activeID)
    }

    private func devToolsTab(id: UUID) -> DevToolsTab? {
        for item in session {
            if case .devtools(let tab) = item, tab.id == id {
                return tab
            }
        }
        return nil
    }

    private func devToolsTab(forSource id: UUID) -> DevToolsTab? {
        for item in session {
            if case .devtools(let tab) = item, tab.sourceID == id {
                return tab
            }
        }
        return nil
    }

    private func devToolsSourceID(of item: SessionTab) -> UUID? {
        if case .devtools(let tab) = item {
            return tab.sourceID
        }
        return nil
    }

    /// On screen: the DevTools tab is selected, or it sits in the split that is showing.
    private func devToolsIsShowing(_ tools: DevToolsTab) -> Bool {
        if activeID == tools.id {
            return true
        }
        guard tiles.isSplitVisible(activeID: activeID), let layout = tiles.layout else { return false }
        return layout.contains(tools.id)
    }

    private func devToolsTabAnywhere(sourceID: UUID) -> DevToolsTab? {
        if let tools = devToolsTab(forSource: sourceID) {
            return tools
        }
        for controller in browserWindows() where controller !== self {
            if let tools = controller.devToolsTab(forSource: sourceID) {
                return tools
            }
        }
        return nil
    }

    func toggleWebInspector(_ sender: Any?) {
        _ = sender
        if let tools = activeDevToolsTab() {
            closeTab(id: tools.id)
            return
        }
        guard let source = focusedWebInspectorTarget() else { return }
        if let tools = devToolsTab(forSource: source.id) {
            if devToolsIsShowing(tools) {
                closeTab(id: tools.id)
            } else {
                revealDevTools(tools, afterReveal: nil)
            }
            return
        }
        for controller in browserWindows() where controller !== self {
            if let tools = controller.devToolsTab(forSource: source.id) {
                _ = controller.focusTab(id: tools.id)
                return
            }
        }
        openDevTools(for: source, afterReveal: nil)
    }

    func startElementSelection(_ sender: Any?) {
        _ = sender
        guard let source = focusedWebInspectorTarget() else { return }
        openOrFocusDevTools(for: source) { tools in
            tools.toggleElementSelection()
        }
    }

    func showJavaScriptConsole(_ sender: Any?) {
        _ = sender
        guard let source = focusedWebInspectorTarget() else { return }
        openOrFocusDevTools(for: source) { tools in
            _ = tools.focusConsole()
        }
    }

    private func openOrFocusDevTools(for source: BrowserTab, after: @escaping (DevToolsTab) -> Void) {
        if let tools = devToolsTab(forSource: source.id) {
            if activeID == tools.id {
                after(tools)
            } else {
                revealDevTools(tools) { after(tools) }
            }
            return
        }
        for controller in browserWindows() where controller !== self {
            if let tools = controller.devToolsTab(forSource: source.id) {
                _ = controller.focusTab(id: tools.id)
                after(tools)
                return
            }
        }
        openDevTools(for: source) { [weak self] in
            guard let self else { return }
            if let tools = self.devToolsTabAnywhere(sourceID: source.id) {
                after(tools)
            }
        }
    }

    private func revealDevTools(_ tools: DevToolsTab, afterReveal: (() -> Void)?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        announcedPaneID = tools.id
        activateTab(id: tools.id, switching: true)
        syncBars(progressOnly: false)
        focusPaneContentIfNeeded()
        afterReveal?()
    }

    private func openDevTools(for source: BrowserTab, afterReveal: (() -> Void)?) {
        if let existing = devToolsTab(forSource: source.id) {
            revealDevTools(existing, afterReveal: afterReveal)
            return
        }
        for controller in browserWindows() where controller !== self {
            if let existing = controller.devToolsTab(forSource: source.id) {
                _ = controller.focusTab(id: existing.id)
                afterReveal?()
                return
            }
        }
        inspectionOpenInFlight.insert(source.id)
        let tools: DevToolsTab
        if let parked = takeSuspended(sourceID: source.id) {
            tools = parked
            configure(tools, source: source)
        } else {
            let host = takeStandbyHost(sourceID: source.id) ?? WebInspectorHost()
            tools = DevToolsTab(source: source, host: host)
            configure(tools, source: source)
        }
        let insertAt = (session.firstIndex(where: { $0.id == source.id }) ?? (session.count - 1)) + 1
        let clamped = min(max(insertAt, 0), session.count)
        session.insert(.devtools(tools), at: clamped)
        let memory = devToolsMemory[source.id]
        if memory?.windowed == true, relocateDevToolsToNewWindow(id: tools.id) {
            inspectionOpenInFlight.remove(source.id)
            announce("Opened DevTools for \(tools.pageTitle), window")
            afterReveal?()
            return
        }
        if memory?.poppedOut == true {
            finishOpen(tools, spoken: "tab", afterReveal: afterReveal)
            return
        }
        if let memory {
            let placed = placeDevToolsResolved(
                tools: tools,
                sourceID: source.id,
                side: memory.side,
                fraction: memory.pageFraction
            )
            let spoken = placed ? (tiles.layout?.spokenPlace(of: tools.id) ?? "pane") : "tab"
            if placed {
                rememberDevToolsPair(source: source.id, devtools: tools.id)
            }
            finishOpen(tools, spoken: spoken, afterReveal: afterReveal)
            return
        }
        applyDefaultPlacement(source: source, tools: tools, afterReveal: afterReveal)
    }

    private func applyDefaultPlacement(source: BrowserTab, tools: DevToolsTab, afterReveal: (() -> Void)?) {
        let width = Double(window?.frame.width ?? 1360)
        let showing = tiles.isSplitVisible(activeID: activeID)
        let sourceIsTiled = showing && (tiles.layout?.contains(source.id) == true)
        let reading = sourceIsTiled ? (tiles.layout?.tabIDs() ?? []) : []
        let plan = DevToolsPlacement.opening(
            sourceIsTiled: sourceIsTiled,
            paneCount: sourceIsTiled ? reading.count : 1,
            windowWidth: width,
            readingOrder: reading,
            source: source.id
        )
        let side: DevToolsSide
        let fraction: Double
        switch plan {
        case .pair(let axis, let pageFraction, let devtoolsFirst):
            if axis == .vertical {
                side = devtoolsFirst ? .above : .below
            } else {
                side = devtoolsFirst ? .left : .right
            }
            fraction = pageFraction
        case .insertRight(let sourceKeeps):
            side = .right
            fraction = sourceKeeps
        case .replace:
            side = .right
            fraction = DevToolsPlacement.pageFraction
        }
        let placed = placeDevToolsResolved(tools: tools, sourceID: source.id, side: side, fraction: fraction)
        if placed {
            rememberDevToolsPair(source: source.id, devtools: tools.id)
        }
        let spoken = placed ? (tiles.layout?.spokenPlace(of: tools.id) ?? "pane") : "tab"
        finishOpen(tools, spoken: spoken, afterReveal: afterReveal)
    }

    private func finishOpen(_ tools: DevToolsTab, spoken: String, afterReveal: (() -> Void)?) {
        announcedPaneID = tools.id
        activateTab(id: tools.id, switching: true)
        syncBars(progressOnly: false)
        announce("Opened DevTools for \(tools.pageTitle), \(spoken)")
        focusPaneContentIfNeeded()
        inspectionOpenInFlight.remove(tools.sourceID)
        afterReveal?()
    }

    /// At four panes, the last non-source pane returns to the strip before DevTools is placed.
    @discardableResult
    private func placeDevToolsResolved(tools: DevToolsTab, sourceID: UUID, side: DevToolsSide, fraction: Double) -> Bool {
        guard session.contains(where: { $0.id == sourceID }) else { return false }
        let layout = tiles.layout
        let alreadyIn = layout?.contains(tools.id) == true
        let sourceInSplit = layout?.isSplit == true && layout?.contains(sourceID) == true
        let count = layout?.tabIDs().count ?? 0
        if !alreadyIn, sourceInSplit, count >= TileArrangement.maximumPanes {
            guard let reading = layout?.tabIDs(),
                  let victim = DevToolsPlacement.paneToReplace(readingOrder: reading, source: sourceID) else {
                return false
            }
            let previous = layout
            let title = tabDisplayTitle(id: victim)
            _ = tiles.remove(tabID: victim)
            guard tiles.placeDevTools(devtools: tools.id, beside: sourceID, side: side, pageFraction: fraction) else {
                if let previous {
                    tiles.replaceLayout(previous)
                }
                return false
            }
            if let previous {
                showFullSplitToast(title: title, previous: previous, devtoolsID: tools.id)
            }
            return true
        }
        return tiles.placeDevTools(devtools: tools.id, beside: sourceID, side: side, pageFraction: fraction)
    }

    private func configure(_ tools: DevToolsTab, source: BrowserTab) {
        tools.onModeChange = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.noteDevToolsFailureIfNeeded()
                    self?.syncBars(progressOnly: false)
                }
            }
        }
        tools.host.onFrontendLoaded = { [weak self, weak source] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let source else { return }
                    if self.inspectionOpenInFlight.contains(source.id) { return }
                    self.noteInspectorAppeared(source: source)
                }
            }
        }
        _ = source
    }

    private func noteDevToolsFailureIfNeeded() {
        guard !didAlertDevToolsFailure else { return }
        let failed = session.contains { item in
            if case .devtools(let tools) = item {
                return tools.host.failedEntirely
            }
            return false
        }
        guard failed else { return }
        didAlertDevToolsFailure = true
        let alert = NSAlert()
        alert.messageText = "Web Inspector could not open"
        alert.informativeText = "Right-click the page and choose Inspect Element."
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    private func noteInspectorAppeared(source: BrowserTab) {
        if inspectionOpenInFlight.contains(source.id) { return }
        if devToolsTabAnywhere(sourceID: source.id) != nil { return }
        openDevTools(for: source, afterReveal: nil)
    }

    private func noteInspectionMenus() {
        guard settings.settings.developerToolsEnabled else { return }
        for item in session {
            guard case .web(let tab) = item, tab.surface == .web else { continue }
            guard WebInspectorHost.isBeingInspected(tab.webView) else { continue }
            noteInspectorAppeared(source: tab)
        }
    }

    private func ensureStandby(for tab: BrowserTab) {
        guard tab.surface == .web, settings.settings.developerToolsEnabled else {
            removeStandby(tab.id)
            return
        }
        if devToolsTab(forSource: tab.id) != nil || suspendedDevTools[tab.id] != nil {
            return
        }
        if standbyHosts[tab.id] != nil {
            return
        }
        guard let content = window?.contentView else { return }
        let view = DevToolsStandbyView(frame: NSRect(x: -2000, y: -2000, width: 800, height: 600))
        content.addSubview(view)
        let host = WebInspectorHost()
        host.onFrontendLoaded = { [weak self, weak tab] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    self.noteInspectorAppeared(source: tab)
                }
            }
        }
        host.prepareStandby(webView: tab.webView, container: view)
        standbyHosts[tab.id] = host
        standbyViews[tab.id] = view
    }

    private func removeStandby(_ id: UUID) {
        standbyHosts.removeValue(forKey: id)?.shutdown()
        standbyViews.removeValue(forKey: id)?.removeFromSuperview()
    }

    private func takeStandbyHost(sourceID: UUID) -> WebInspectorHost? {
        standbyViews.removeValue(forKey: sourceID)?.removeFromSuperview()
        return standbyHosts.removeValue(forKey: sourceID)
    }

    private func takeSuspended(sourceID: UUID) -> DevToolsTab? {
        guard let parked = suspendedDevTools[sourceID] else { return nil }
        let fresh = devToolsHiddenAt[sourceID].map { Date().timeIntervalSince($0) <= 30 } ?? false
        suspendedDevTools[sourceID] = nil
        devToolsHiddenAt[sourceID] = nil
        guard fresh else {
            parked.shutdown()
            parked.container.removeFromSuperview()
            return nil
        }
        parked.container.alphaValue = 1
        return parked
    }

    private func armDevToolsExpiry(sourceID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated {
                self?.expireSuspendedDevTools(sourceID: sourceID)
            }
        }
    }

    private func expireSuspendedDevTools(sourceID: UUID) {
        guard let hidden = devToolsHiddenAt[sourceID], Date().timeIntervalSince(hidden) >= 30 else { return }
        guard let parked = suspendedDevTools.removeValue(forKey: sourceID) else { return }
        parked.shutdown()
        parked.container.removeFromSuperview()
        devToolsHiddenAt[sourceID] = nil
    }

    /// Source closed in another window. Shuts this window's copy down without calling back.
    func closePartnerDevTools(sourceID: UUID) {
        if let parked = suspendedDevTools.removeValue(forKey: sourceID) {
            parked.shutdown()
            parked.container.removeFromSuperview()
        }
        devToolsHiddenAt[sourceID] = nil
        devToolsMemory[sourceID] = nil
        guard let tools = devToolsTab(forSource: sourceID),
              let index = session.firstIndex(where: { $0.id == tools.id }) else {
            return
        }
        tools.shutdown()
        tools.container.removeFromSuperview()
        let closingActive = tools.id == activeID
        session.remove(at: index)
        let preferred = tiles.remove(tabID: tools.id)
        if session.isEmpty {
            closeConfirmed = true
            window?.close()
            return
        }
        if closingActive {
            let next = preferred.flatMap { id in session.contains(where: { $0.id == id }) ? id : nil }
                ?? session[min(index, session.count - 1)].id
            activateTab(id: next, switching: true)
        }
        syncBars(progressOnly: false)
        noteSessionChange()
    }

    private func makeRestoredDevTools(source: BrowserTab) -> DevToolsTab {
        let host = takeStandbyHost(sourceID: source.id) ?? WebInspectorHost()
        let tools = DevToolsTab(source: source, host: host)
        configure(tools, source: source)
        return tools
    }

    private func syncDevToolsBars(_ tools: DevToolsTab) {
        let source = webTab(id: tools.sourceID) ?? webTabInAnyWindow(id: tools.sourceID)
        let loading = source?.surface == .web && source?.isLoading == true && (source?.estimatedProgress ?? 1) < 1
        frameBar.showsProgress = loading
        frameBar.fraction = loading ? (source?.estimatedProgress ?? 0) : 0
        backButton.isEnabled = source?.canGoBack ?? false
        forwardButton.isEnabled = source?.canGoForward ?? false
        reloadButton.isEnabled = source?.surface == .web
        reloadButton.toolTip = loading ? "Stop" : "Reload"
        reloadButton.setAccessibilityLabel(loading ? "Stop" : "Reload")
        let url = source?.displayedURL ?? tools.sourceURL
        let allowed = Self.allowsBookmark(url)
        let bookmarked = allowed && url.flatMap { bookmarks.bookmark(matchingURL: $0.absoluteString) } != nil
        addressField.presentDevTools(url: url, bookmarked: bookmarked, canBookmark: allowed)
        window?.title = "\(tools.displayTitle) — \(AppInfo.displayName)"
        feedHealth(host: url?.host, url: url, rememberAs: source?.id)
        refreshAppearanceProbe()
        let inSplit = tiles.isSplitVisible(activeID: tools.id)
        let sourceHere = webTab(id: tools.sourceID) != nil
        setLinkedChip(visible: !inSplit || !sourceHere, title: tools.pageTitle, url: url?.absoluteString)
        tabRegion.update(items: stripItems(selectedID: tools.id))
        terminalHost.isHidden = true
        bookmarksPage.isHidden = true
        newTabPage.isHidden = true
        webContainer.isHidden = inSplit
        applyTileVisibility()
    }

    private func setLinkedChip(visible: Bool, title: String, url: String?) {
        if visible {
            linkedChip.present(title: title, url: url)
            linkedChipLeading?.constant = MonoMetrics.itemGap
            linkedChipWidth?.constant = measuredLinkedChipWidth(title: title)
            linkedChip.isHidden = false
        } else {
            linkedChip.isHidden = true
            linkedChipLeading?.constant = 0
            linkedChipWidth?.constant = 0
        }
    }

    private func measuredLinkedChipWidth(title: String) -> CGFloat {
        let font = Theme.font(size: 11.5, weight: .regular)
        let prefix = ("Linked to:" as NSString).size(withAttributes: [.font: font]).width
        let titleWidth = min(220, (title as NSString).size(withAttributes: [.font: font]).width)
        return 6 + 14 + 6 + prefix + 4 + titleWidth + 10
    }

    private func linkingDevToolsPartners(_ rows: [TabStripItem]) -> [TabStripItem] {
        var toolsBySource: [UUID: UUID] = [:]
        for item in session {
            if case .devtools(let tab) = item, session.contains(where: { $0.id == tab.sourceID }) {
                toolsBySource[tab.sourceID] = tab.id
            }
        }
        guard !toolsBySource.isEmpty else { return rows }
        return rows.map { row in
            var copy = row
            if let toolsID = toolsBySource[row.id] {
                copy.partnerID = toolsID
            }
            return copy
        }
    }

    /// DevTools stays immediately after its source. A tab whose source is gone is removed.
    /// A tab whose source lives in another window stays put.
    private func pinDevToolsOrder() -> Bool {
        var removed = false
        var partners: [UUID: UUID] = [:]
        var drop: [DevToolsTab] = []
        for item in session {
            guard case .devtools(let tab) = item else { continue }
            if session.contains(where: { $0.id == tab.sourceID }) {
                partners[tab.id] = tab.sourceID
            } else if windowHosting(tab: tab.sourceID) == nil {
                drop.append(tab)
            }
        }
        for tab in drop {
            tab.shutdown()
            tab.container.removeFromSuperview()
            session.removeAll { $0.id == tab.id }
            _ = tiles.remove(tabID: tab.id)
            devToolsMemory[tab.sourceID] = nil
            devToolsHiddenAt[tab.sourceID] = nil
            removed = true
        }
        if let activeID, !session.contains(where: { $0.id == activeID }) {
            self.activeID = session.first?.id
        }
        if session.isEmpty {
            closeConfirmed = true
            window?.close()
            return true
        }
        guard !partners.isEmpty else { return removed }
        let plan = DevToolsStrip.pinning(session.map(\.id), partners: partners)
        return applySessionOrder(plan.order) || removed
    }

    private func parkInactiveDevTools() {
        let showingSplit = tiles.isSplitVisible(activeID: activeID)
        let showing = showingSplit ? Set(tiles.tabIDs()) : []
        for item in session {
            guard case .devtools(let tools) = item else { continue }
            if item.id == activeID || showing.contains(item.id) { continue }
            if tools.container.superview === webContainer {
                tools.container.removeFromSuperview()
            }
        }
    }

    private func attachVisibleDevTools() {
        for item in session {
            guard case .devtools(let tools) = item else { continue }
            guard tools.container.window != nil else { continue }
            tools.attachAndShowIfNeeded()
        }
    }

    /// Placement memory lives on the window that holds the source page.
    private func storeDevToolsMemory(_ memory: DevToolsPlaceMemory, sourceID: UUID) {
        let home = windowHosting(tab: sourceID) ?? self
        if home !== self {
            devToolsMemory[sourceID] = nil
        }
        home.devToolsMemory[sourceID] = memory
    }

    private func rememberDevToolsPair(source: UUID, devtools: UUID) {
        let side = tiles.layout.flatMap { DevToolsPlacement.side(of: devtools, relativeTo: source, in: $0) } ?? .right
        let fraction = tiles.layout.flatMap { DevToolsPlacement.pageFraction(source: source, devtools: devtools, in: $0) }
            ?? DevToolsPlacement.pageFraction
        storeDevToolsMemory(
            DevToolsPlaceMemory(side: side, pageFraction: fraction, poppedOut: false, windowed: false),
            sourceID: source
        )
    }

    private func rememberDevToolsWindowFrameIfNeeded() {
        guard let frame = window?.frame, !session.isEmpty else { return }
        let onlyWindowedTools = session.allSatisfy { item in
            guard case .devtools(let tools) = item else { return false }
            return !session.contains(where: { $0.id == tools.sourceID })
        }
        guard onlyWindowedTools else { return }
        AppDelegate.rememberDevToolsWindowFrame(frame)
    }

    private func showSourceOfActiveDevTools() {
        guard let tools = activeDevToolsTab() else { return }
        focusSource(of: tools)
    }

    private func focusSource(of tools: DevToolsTab) {
        if webTab(id: tools.sourceID) != nil {
            _ = focusTab(id: tools.sourceID)
            return
        }
        if let home = windowHosting(tab: tools.sourceID) {
            _ = home.focusTab(id: tools.sourceID)
        }
    }

    private func tabDisplayTitle(id: UUID) -> String {
        guard let item = session.first(where: { $0.id == id }) else { return "Tab" }
        switch item {
        case .web(let tab):
            return tab.title
        case .terminal(let tab):
            return tab.name
        case .devtools(let tab):
            return tab.pageTitle
        }
    }

    private func showFullSplitToast(title: String, previous: TileLayout, devtoolsID: UUID) {
        toastUndoLayout = previous
        toastUndoDevToolsID = devtoolsID
        splitToast.present(title: title)
        splitToast.isHidden = false
        toastTimer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissSplitToast()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        toastTimer = timer
    }

    private func dismissSplitToast() {
        toastTimer?.invalidate()
        toastTimer = nil
        splitToast.isHidden = true
        toastUndoLayout = nil
        toastUndoDevToolsID = nil
    }

    private func undoFullSplitToast() {
        guard let previous = toastUndoLayout else { return }
        let toolsID = toastUndoDevToolsID
        toastTimer?.invalidate()
        toastTimer = nil
        splitToast.isHidden = true
        toastUndoLayout = nil
        toastUndoDevToolsID = nil
        tiles.replaceLayout(previous)
        if let toolsID, let tools = devToolsTab(id: toolsID) {
            var memory = devToolsMemory[tools.sourceID] ?? DevToolsPlaceMemory(
                side: .right,
                pageFraction: DevToolsPlacement.pageFraction,
                poppedOut: true,
                windowed: false
            )
            memory.poppedOut = true
            memory.windowed = false
            devToolsMemory[tools.sourceID] = memory
        }
        if let id = activeID, !previous.contains(id) {
            let focus = previous.focusedTabID
            if session.contains(where: { $0.id == focus }) {
                activateTab(id: focus, switching: false)
            }
        }
        syncBars(progressOnly: false)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: tiles.canvas, notification: .announcementRequested, userInfo: [
            .announcement: message as NSString
        ])
    }

    private func devToolsDropCaption(dragging: UUID, anchor: UUID, edge: TileEdge) -> String {
        guard sessionKind(id: dragging) == .devtools, let tools = devToolsTab(id: dragging) else { return "" }
        guard anchor == tools.sourceID || anchor == dragging else { return "" }
        return DevToolsSide(edge: edge).dropLabel
    }

    private func movePartnerDevTools(of tab: SessionTab, to target: BrowserWindowController) {
        guard case .web = tab else { return }
        let sourceID = tab.id
        if let memory = devToolsMemory.removeValue(forKey: sourceID) {
            target.devToolsMemory[sourceID] = memory
        }
        if let hidden = devToolsHiddenAt.removeValue(forKey: sourceID) {
            target.devToolsHiddenAt[sourceID] = hidden
        }
        if let parked = suspendedDevTools.removeValue(forKey: sourceID) {
            target.suspendedDevTools[sourceID] = parked
            parked.container.removeFromSuperview()
            if let content = target.window?.contentView {
                parked.container.frame = NSRect(x: -2000, y: -2000, width: 800, height: 600)
                content.addSubview(parked.container)
            }
        }
        guard let tools = devToolsTab(forSource: sourceID) else { return }
        let wasInSplit = tiles.layout?.contains(tools.id) == true
        let memory = target.devToolsMemory[sourceID]
        guard let index = indexOfTab(id: tools.id), let item = detachTab(at: index) else { return }
        let insertAt = (target.indexOfTab(id: sourceID) ?? (target.session.count - 1)) + 1
        target.adopt(tab: item, at: insertAt)
        let popped = memory?.poppedOut == true || memory?.windowed == true
        let targetLayout = target.tiles.layout
        let unrelatedSplit = targetLayout?.isSplit == true && targetLayout?.contains(sourceID) != true
        if wasInSplit, !popped, !unrelatedSplit {
            let side = memory?.side ?? .right
            let fraction = memory?.pageFraction ?? DevToolsPlacement.pageFraction
            _ = target.placeDevToolsResolved(tools: tools, sourceID: sourceID, side: side, fraction: fraction)
        }
        target.activateTab(id: sourceID, switching: false)
        target.syncBars(progressOnly: false)
    }

    private func noteDevToolsDraggedToAnotherWindow(_ tab: SessionTab) {
        guard case .devtools(let tools) = tab else { return }
        let sourceID = tools.sourceID
        let home = windowHosting(tab: sourceID) ?? self
        let together = home.session.contains(where: { $0.id == tools.id })
        var memory = home.devToolsMemory[sourceID] ?? DevToolsPlaceMemory(
            side: .right,
            pageFraction: DevToolsPlacement.pageFraction,
            poppedOut: false,
            windowed: false
        )
        if together {
            memory.poppedOut = true
            memory.windowed = false
        } else {
            memory.windowed = true
            memory.poppedOut = false
        }
        home.devToolsMemory[sourceID] = memory
    }

    private func moveDevTools(id: UUID, to side: DevToolsSide) {
        guard let tools = devToolsTab(id: id) else { return }
        let sourceID = tools.sourceID
        if !session.contains(where: { $0.id == sourceID }) {
            guard let home = windowHosting(tab: sourceID), home !== self,
                  let index = indexOfTab(id: tools.id),
                  let tab = detachTab(at: index) else { return }
            let insertAt = (home.indexOfTab(id: sourceID) ?? (home.session.count - 1)) + 1
            home.adopt(tab: tab, at: insertAt)
            home.moveDevTools(id: tools.id, to: side)
            closeIfEmpty()
            return
        }
        guard placeDevToolsResolved(
            tools: tools,
            sourceID: sourceID,
            side: side,
            fraction: DevToolsPlacement.pageFraction
        ) else { return }
        var memory = devToolsMemory[sourceID] ?? DevToolsPlaceMemory(
            side: side,
            pageFraction: DevToolsPlacement.pageFraction,
            poppedOut: false,
            windowed: false
        )
        memory.side = side
        memory.pageFraction = DevToolsPlacement.pageFraction
        memory.poppedOut = false
        memory.windowed = false
        devToolsMemory[sourceID] = memory
        announcedPaneID = tools.id
        activateTab(id: tools.id, switching: false)
        syncBars(progressOnly: false)
        announce(side.moveAnnouncement)
        focusPaneContentIfNeeded()
    }

    private func popOutDevTools(id: UUID) {
        guard let tools = devToolsTab(id: id) else { return }
        _ = tiles.remove(tabID: id)
        var memory = devToolsMemory[tools.sourceID] ?? DevToolsPlaceMemory(
            side: .right,
            pageFraction: DevToolsPlacement.pageFraction,
            poppedOut: true,
            windowed: false
        )
        memory.poppedOut = true
        memory.windowed = false
        storeDevToolsMemory(memory, sourceID: tools.sourceID)
        announcedPaneID = id
        activateTab(id: id, switching: true)
        syncBars(progressOnly: false)
        focusPaneContentIfNeeded()
    }

    @discardableResult
    private func relocateDevToolsToNewWindow(id: UUID) -> Bool {
        guard let app = NSApp.delegate as? AppDelegate else { return false }
        guard let tools = devToolsTab(id: id), let index = indexOfTab(id: id) else { return false }
        let sourceID = tools.sourceID
        var memory = devToolsMemory[sourceID] ?? DevToolsPlaceMemory(
            side: .right,
            pageFraction: DevToolsPlacement.pageFraction,
            poppedOut: false,
            windowed: true
        )
        memory.windowed = true
        memory.poppedOut = false
        guard let tab = detachTab(at: index) else { return false }
        if session.contains(where: { $0.id == sourceID }) {
            devToolsMemory[sourceID] = memory
        } else if let home = windowHosting(tab: sourceID) {
            home.devToolsMemory[sourceID] = memory
        } else {
            devToolsMemory[sourceID] = memory
        }
        app.presentDevToolsWindow(tab)
        closeIfEmpty()
        return true
    }

    private func devToolsContextMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        let withPage: Bool = {
            guard let tools = devToolsTab(id: id), let layout = tiles.layout, layout.isSplit else { return false }
            return layout.contains(id) && layout.contains(tools.sourceID)
        }()
        if !withPage {
            menu.addItem(menuItem("Split with Page", action: #selector(splitDevToolsWithPage(_:)), id: id))
        }
        let move = NSMenuItem(title: "Move", action: nil, keyEquivalent: "")
        move.submenu = devToolsMoveMenu(for: id)
        menu.addItem(move)
        menu.addItem(menuItem("Pop Out to Tab", action: #selector(popOutDevToolsItem(_:)), id: id))
        menu.addItem(menuItem("Move to New Window", action: #selector(moveDevToolsToNewWindow(_:)), id: id))
        menu.addItem(.separator())
        menu.addItem(menuItem("Reload Source", action: #selector(reloadDevToolsSource(_:)), id: id))
        menu.addItem(menuItem("Show Source Tab", action: #selector(showDevToolsSource(_:)), id: id))
        menu.addItem(.separator())
        let close = menuItem("Close DevTools", action: #selector(closeDevToolsFromMenu(_:)), id: id)
        close.keyEquivalent = "i"
        close.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(close)
        return menu
    }

    private func devToolsMoveMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        let current = currentDevToolsSide(id: id)
        for side in [DevToolsSide.left, .right, .above, .below] {
            let item = NSMenuItem(title: side.menuTitle, action: #selector(moveDevToolsToSide(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.tag = tag(for: side)
            item.state = side == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func showDevToolsOverflow(id: UUID, anchor: NSView) {
        let menu = NSMenu()
        menu.addItem(menuItem("Move to New Window", action: #selector(moveDevToolsToNewWindow(_:)), id: id))
        menu.addItem(menuItem("Reload Source", action: #selector(reloadDevToolsSource(_:)), id: id))
        menu.addItem(menuItem("Show Source Tab", action: #selector(showDevToolsSource(_:)), id: id))
        menu.addItem(menuItem("Close DevTools", action: #selector(closeDevToolsFromMenu(_:)), id: id))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    private func currentDevToolsSide(id: UUID) -> DevToolsSide? {
        guard let tools = devToolsTab(id: id), let layout = tiles.layout else { return nil }
        return DevToolsPlacement.side(of: tools.id, relativeTo: tools.sourceID, in: layout)
    }

    private func tag(for side: DevToolsSide) -> Int {
        switch side {
        case .left: return 1
        case .right: return 2
        case .above: return 3
        case .below: return 4
        }
    }

    private func devToolsSide(tag: Int) -> DevToolsSide? {
        switch tag {
        case 1: return .left
        case 2: return .right
        case 3: return .above
        case 4: return .below
        default: return nil
        }
    }

    private func menuDevToolsID(_ sender: Any?) -> UUID? {
        (sender as? NSMenuItem)?.representedObject as? UUID
    }

    @objc func moveDevToolsLeft(_ sender: Any?) {
        _ = sender
        guard let id = activeDevToolsTab()?.id else { return }
        moveDevTools(id: id, to: .left)
    }

    @objc func moveDevToolsRight(_ sender: Any?) {
        _ = sender
        guard let id = activeDevToolsTab()?.id else { return }
        moveDevTools(id: id, to: .right)
    }

    @objc func moveDevToolsAbove(_ sender: Any?) {
        _ = sender
        guard let id = activeDevToolsTab()?.id else { return }
        moveDevTools(id: id, to: .above)
    }

    @objc func moveDevToolsBelow(_ sender: Any?) {
        _ = sender
        guard let id = activeDevToolsTab()?.id else { return }
        moveDevTools(id: id, to: .below)
    }

    @objc func moveDevToolsToSide(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let side = devToolsSide(tag: item.tag) else { return }
        guard let id = (item.representedObject as? UUID) ?? activeDevToolsTab()?.id else { return }
        moveDevTools(id: id, to: side)
    }

    @objc func popOutDevToolsItem(_ sender: Any?) {
        guard let id = menuDevToolsID(sender) ?? activeDevToolsTab()?.id else { return }
        popOutDevTools(id: id)
    }

    @objc func moveDevToolsToNewWindow(_ sender: Any?) {
        guard let id = menuDevToolsID(sender) ?? activeDevToolsTab()?.id else { return }
        relocateDevToolsToNewWindow(id: id)
    }

    @objc func reloadDevToolsSource(_ sender: Any?) {
        let id = menuDevToolsID(sender)
        let tools = id.flatMap { devToolsTab(id: $0) } ?? activeDevToolsTab()
        tools?.reloadSource()
    }

    @objc func showDevToolsSource(_ sender: Any?) {
        if let id = menuDevToolsID(sender), let tools = devToolsTab(id: id) {
            focusSource(of: tools)
            return
        }
        showSourceOfActiveDevTools()
    }

    @objc func closeDevToolsFromMenu(_ sender: Any?) {
        guard let id = menuDevToolsID(sender) ?? activeDevToolsTab()?.id else { return }
        closeTab(id: id)
    }

    @objc func splitDevToolsWithPage(_ sender: Any?) {
        guard let id = menuDevToolsID(sender) ?? activeDevToolsTab()?.id else { return }
        moveDevTools(id: id, to: .right)
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
                let line = "WYVERN_POPOVER_WINDOW_ID=\(number)\n"
                FileHandle.standardOutput.write(Data(line.utf8))
                fflush(stdout)
            }
        }
    }
}

extension BrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeTab(_:)):
            return !session.isEmpty
        case #selector(splitRight(_:)):
            let anchor = (menuItem.representedObject as? UUID) ?? activeID
            guard let anchor else { return false }
            return canAddPane(beside: anchor, edge: .right)
        case #selector(splitDown(_:)):
            let anchor = (menuItem.representedObject as? UUID) ?? activeID
            guard let anchor else { return false }
            return canAddPane(beside: anchor, edge: .down)
        case #selector(splitWithCurrentTab(_:)):
            guard let clicked = menuItem.representedObject as? UUID,
                  session.contains(where: { $0.id == clicked }) else { return false }
            if clicked == activeID {
                return canAddPane(beside: clicked, edge: .right)
            }
            if let layout = tiles.layout, layout.isSplit {
                if layout.tabIDs().count >= TileArrangement.maximumPanes, !layout.contains(clicked) {
                    return false
                }
                if !layout.contains(clicked), let current = activeID, !layout.contains(current) {
                    return false
                }
            }
            return true
        case #selector(addToSplit(_:)):
            guard let id = menuItem.representedObject as? UUID,
                  let layout = tiles.layout, layout.isSplit, !layout.contains(id) else { return false }
            if layout.tabIDs().count >= TileArrangement.maximumPanes {
                menuItem.toolTip = "Split View holds up to 4 tabs"
                return false
            }
            return true
        case #selector(removeFromSplit(_:)):
            guard let id = menuItem.representedObject as? UUID else { return false }
            return tiles.layout?.contains(id) == true
        case #selector(closePane(_:)),
             #selector(focusNextPane(_:)),
             #selector(focusPreviousPane(_:)),
             #selector(focusPaneLeft(_:)),
             #selector(focusPaneRight(_:)),
             #selector(focusPaneUp(_:)),
             #selector(focusPaneDown(_:)),
             #selector(swapPaneLeft(_:)),
             #selector(swapPaneRight(_:)),
             #selector(equalizePanes(_:)):
            return tiles.isSplitVisible(activeID: activeID)
        case #selector(unsplit(_:)):
            return tiles.hasSavedSplit
        case #selector(applyLayout(_:)):
            return activeID != nil
        case #selector(moveDevToolsLeft(_:)),
             #selector(moveDevToolsRight(_:)),
             #selector(moveDevToolsAbove(_:)),
             #selector(moveDevToolsBelow(_:)):
            return activeDevToolsTab() != nil
        case #selector(popOutDevToolsItem(_:)),
             #selector(moveDevToolsToNewWindow(_:)),
             #selector(reloadDevToolsSource(_:)),
             #selector(showDevToolsSource(_:)),
             #selector(closeDevToolsFromMenu(_:)),
             #selector(splitDevToolsWithPage(_:)),
             #selector(moveDevToolsToSide(_:)):
            let id = (menuItem.representedObject as? UUID) ?? activeDevToolsTab()?.id
            guard let id else { return false }
            return devToolsTab(id: id) != nil
        default:
            return true
        }
    }

    private func canAddPane(beside anchor: UUID, edge: TileEdge) -> Bool {
        guard session.contains(where: { $0.id == anchor }) else { return false }
        guard let layout = tiles.layout, layout.isSplit else { return true }
        if !layout.contains(anchor) {
            return layout.tabIDs().count < TileArrangement.maximumPanes
        }
        return layout.expanded(adding: UUID(), beside: anchor, edge: edge) != nil
    }
}
