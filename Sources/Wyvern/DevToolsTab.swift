// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit
import WebKit

/// One DevTools tab bound to a source page. The container is what pane tiling hosts.
/// Inspector shutdown is explicit. `deinit` does not touch WebKit or AppKit.
@MainActor
final class DevToolsTab: NSObject {
    let id: UUID
    let sourceID: UUID
    let container: DevToolsContainerView
    let host: WebInspectorHost
    private(set) var pageTitle: String
    private weak var source: BrowserTab?
    private(set) var usesWindowFallback = false
    private var didRequestShow = false
    private var inspectorSettled = false
    /// `suspend` hid the inspector. The next attach calls WebKit again so a reopen within 30 s can restore it.
    private var needsReveal = false

    var displayTitle: String { "DevTools: \(pageTitle)" }
    var accessibilityName: String { "DevTools for \(pageTitle)" }
    var accessibilityLabel: String { "DevTools for \(pageTitle), tab" }

    var onModeChange: (() -> Void)?

    init(id: UUID = UUID(), source: BrowserTab, host: WebInspectorHost) {
        self.id = id
        self.sourceID = source.id
        self.source = source
        self.host = host
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pageTitle = title.isEmpty ? "New Tab" : title
        self.container = DevToolsContainerView()
        super.init()
        container.onShowWindow = { [weak self] in
            self?.host.orderCompanionFront()
        }
        host.onMode = { [weak self] mode in
            guard let self else { return }
            self.usesWindowFallback = mode == "window"
            let failed = self.host.failedEntirely
            self.container.showsWindowCard = mode == "window" && !failed
            self.onModeChange?()
        }
    }

    func noteSourceTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != pageTitle else { return }
        pageTitle = trimmed
    }

    /// Docks into the container once it is in a window. A second call does not reopen WebKit,
    /// unless `suspend` asked for a reveal.
    func attachAndShowIfNeeded() {
        if needsReveal, container.window != nil {
            needsReveal = false
            didRequestShow = false
        }
        guard !didRequestShow else { return }
        guard container.window != nil else { return }
        didRequestShow = true
        container.alphaValue = 1
        guard let webView = source?.webView else {
            usesWindowFallback = true
            container.showsWindowCard = true
            host.failHosted()
            return
        }
        container.layoutSubtreeIfNeeded()
        host.showHosted(in: container, webView: webView)
    }

    func toggleElementSelection() {
        host.toggleElementSelection()
    }

    @discardableResult
    func focusConsole() -> Bool {
        host.focusConsole()
    }

    /// Keeps WebKit's panel state when `hide` exists. Used by ⌥⌘I.
    /// The next `attachAndShowIfNeeded` shows it again. `deinit` does not call this.
    func suspend() {
        inspectorSettled = true
        needsReveal = true
        host.suspend()
    }

    func shutdown() {
        inspectorSettled = true
        host.shutdown()
    }

    /// Tab removal closes the inspector unless `suspend` or `shutdown` already ran.
    func finishRemoval() {
        if !inspectorSettled {
            shutdown()
        }
    }

    var focusTarget: NSView {
        container
    }

    var sourceURL: URL? {
        source?.displayedURL
    }

    func reloadSource() {
        guard source?.surface == .web else { return }
        source?.webView.reload()
    }
}

/// Pane content for a DevTools tab. WebKit parents the inspector frontend into this view.
@MainActor
final class DevToolsContainerView: NSView {
    var onShowWindow: (() -> Void)?
    private let card = DevToolsWindowCard()

    var showsWindowCard: Bool = false {
        didSet {
            guard showsWindowCard != oldValue else { return }
            card.isHidden = !showsWindowCard
            if showsWindowCard,
               HostedViewPlacement.shouldRaise(
                   isChildOfTarget: card.superview === self,
                   isFrontmost: subviews.last === card
               ) {
                addSubview(card)
            }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.page.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Web Inspector")
        setAccessibilityIdentifier("wyvern.devtools.container")
        card.isHidden = true
        card.onShow = { [weak self] in
            self?.onShowWindow?()
        }
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Theme.page.cgColor
    }

    override func layout() {
        super.layout()
        let width = min(420, max(240, bounds.width - 48))
        let height: CGFloat = 72
        card.frame = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    override var acceptsFirstResponder: Bool { true }

    /// A parked container stays in the hierarchy at alpha 0 and must not take clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if alphaValue < 0.01 { return nil }
        return super.hitTest(point)
    }
}
