// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore
import Darwin
import WebKit
import Security

// The Xcode 16+ SDK marks these decision handlers MainActor and Sendable.
// The witness must match or WebKit treats the optional method as unimplemented.
#if compiler(>=6)
typealias NavigationDecisionHandler = @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
typealias ResponseDecisionHandler = @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
typealias MediaCaptureDecisionHandler = @MainActor @Sendable (WKPermissionDecision) -> Void
typealias AuthChallengeHandler = @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
#else
typealias NavigationDecisionHandler = (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
typealias ResponseDecisionHandler = (WKNavigationResponsePolicy) -> Void
typealias MediaCaptureDecisionHandler = (WKPermissionDecision) -> Void
typealias AuthChallengeHandler = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
#endif

enum TabSurface: Equatable {
    case web
    case bookmarks
    case newTab
}

extension WebContentSurface {
    init(_ surface: TabSurface) {
        switch surface {
        case .web:
            self = .web
        case .bookmarks:
            self = .bookmarks
        case .newTab:
            self = .newTab
        }
    }
}

extension BrowserTab {
    var kind: TabKind { .web }
}

@MainActor
protocol BrowserTabHost: AnyObject {
    func browserTabDidUpdate(_ tab: BrowserTab, progressOnly: Bool)
    func browserTabDidSettle(_ tab: BrowserTab)
    func browserTab(_ tab: BrowserTab, createWebViewWith configuration: WKWebViewConfiguration) -> WKWebView?
    func browserTabDidRequestClose(_ tab: BrowserTab)
    func browserTab(_ tab: BrowserTab, confirmExternal url: URL)
    func browserTabDeniedFile(_ tab: BrowserTab)
    func browserTab(_ tab: BrowserTab, decideMediaCapture originKey: String, kind: MediaCaptureKind, completion: @escaping (Bool) -> Void)
    func browserTab(_ tab: BrowserTab, permissionChoice originKey: String, kind: SitePermissionKind) -> SitePermissionChoice
    func browserTabDidCancelMediaPrompt(_ tab: BrowserTab)
    func browserTab(_ tab: BrowserTab, hostDidChange host: String?)
    func browserTabDidExitElementFullscreen(_ tab: BrowserTab)
}

extension BrowserTabHost {
    func browserTabDidExitElementFullscreen(_ tab: BrowserTab) {}
}

/// One tab owns one web view. Observations are held here and invalidated on close
/// so the web view does not keep the tab alive.
@MainActor
final class BrowserTab: NSObject, WKNavigationDelegate, WKUIDelegate, @unchecked Sendable {
    let id = UUID()
    let webView: WKWebView
    weak var host: BrowserTabHost?
    private(set) var surface: TabSurface

    private(set) var title = "New Tab"
    private(set) var displayedURL: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var estimatedProgress: Double = 0
    var favicon: NSImage?
    /// Set only when the person typed a file URL. Link-clicked file URLs stay blocked.
    var permittedFileURL: URL?
    /// True from `load()` or a main-frame link click until that navigation commits, finishes, or fails.
    private var userInitiatedNavigation = false
    private var currentNavigation: WKNavigation?
    /// URL of the last committed document. Provisional `webView.url` is not shown over it.
    private var committedURL: URL?
    /// The address the person just submitted. Kept until that load commits or fails.
    private var showingTypedTarget = false

    private var observations: [NSKeyValueObservation] = []
    private var didShutdown = false
    private var faviconGeneration = 0
    private var pendingMediaCancel: (() -> Void)?
    private var pendingMediaOriginHost: String?
    private var popupTimes: [Date] = []
    private let benchHandler: BenchPaintHandler
    private let probeHandler: BlockListProbeHandler
    private var benchDidFinish = false
    private var benchDidRAF = false
    private var cookieObserver: NSObjectProtocol?
    private var developerToolsObserver: NSObjectProtocol?
    private var blockRulesObserver: NSObjectProtocol?
    /// Main-frame allows waiting for `didStartProvisionalNavigation`, so iframe loads do not clear the count.
    private var mainFrameStartsPending = 0
    private var probeSeen = Set<String>()
    private(set) var blockedRequestCount = 0
    /// Escape combo pauses key capture for this tab only. Not written to settings.
    var kvmCaptureSuspended = false
    /// True after the media script has run in the current document.
    private var kvmMediaInstalled = false
    /// True after this web view was set to `InactiveSchedulingPolicy.none` for a KVM origin.
    private var kvmInactivePolicyIsNone = false
    /// True while the in-tab HTML error document is showing, so a failure loading it does not recurse.
    /// The address bar hides its lock for that document: the URL may still be https, which is not a
    /// claim that the connection was authenticated.
    private(set) var isShowingErrorPage = false
    /// Navigation returned by `loadHTMLString` for the error document. Its own start must not clear
    /// the flag. `webView.url` during `didStartProvisionalNavigation` is still the previous document,
    /// so a scheme check on that property cannot tell the error document from the next real load.
    private var errorPageNavigation: WKNavigation?
    /// True until the error document's provisional start is observed. Set before `loadHTMLString`
    /// because that call can invoke `didStart` before it returns a navigation object.
    private var errorPageStartPending = false
    /// Shared session allowlist for certificates the person continued past.
    private let serverTrustAllowlist = ServerTrustAllowlist.shared

    static let blankURL: URL = {
        if let url = URL(string: "about:blank") {
            return url
        }
        preconditionFailure("about:blank must be a valid URL")
    }()

    /// User agent: `applicationNameForUserAgent` is Safari's own `Version/<x.y> Safari/605.1.15`
    /// (`SafariUserAgent`), read from the installed Safari. Without it Google and other sites treat
    /// the bare WKWebView agent as an old browser and serve legacy pages. Do not set
    /// `customUserAgent`, and do not add an app token: the agent must stay identical to Safari's
    /// so Wyvern does not publish anything a page could fingerprint or rely on.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        SafariUserAgent.apply(to: configuration)
        // Unsolicited scripted popups stay blocked. A user gesture still reaches
        // createWebViewWith for target=_blank and window.open. Element fullscreen is on,
        // so video fullscreen buttons work (it is off by default on macOS).
        WebContentDefaults.apply(to: configuration.preferences)
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        if !hardwareAcceleration {
            applySoftwareRendering(configuration.preferences)
        }
        return configuration
    }

    /// Set from settings at launch and when the toggle changes. Affects new web views only.
    static var hardwareAcceleration = true
    /// Points applied as text zoom, or as a document root font-size when text zoom is unavailable.
    static var defaultFontSize = 16
    /// Page zoom percent applied with `WKWebView.pageZoom`.
    static var defaultZoomPercent = 100
    /// When true, ordinary web pages are inspectable. Internal pages stay closed.
    /// Set at launch and when Show Develop menu changes. Off until that setting is on.
    static var developerToolsEnabled = false
    /// Origins in KVM mode. AppDelegate copies this from settings. Other pages are left alone.
    static var kvmSites = KVMSiteList()

    /// WebKit preference keys that turn off GPU canvas and WebGL. Each is set only if KVC accepts it.
    static let softwareRenderingKeys = ["acceleratedDrawingEnabled", "canvasUsesAcceleratedDrawing", "webGLEnabled"]

    /// KVC finds `set<Key>:` or `_set<Key>:`; only those keys are written, so an unknown key cannot throw.
    static func canSet(_ preferences: WKPreferences, key: String) -> Bool {
        let cap = key.prefix(1).uppercased() + key.dropFirst()
        return preferences.responds(to: NSSelectorFromString("set\(cap):"))
            || preferences.responds(to: NSSelectorFromString("_set\(cap):"))
    }

    static func canGet(_ preferences: WKPreferences, key: String) -> Bool {
        let cap = key.prefix(1).uppercased() + key.dropFirst()
        return [key, "_\(key)", "is\(cap)", "_is\(cap)"].contains {
            preferences.responds(to: NSSelectorFromString($0))
        }
    }

    /// Returns the keys that took effect.
    @discardableResult
    static func applySoftwareRendering(_ preferences: WKPreferences) -> [String] {
        var applied: [String] = []
        for key in softwareRenderingKeys where canSet(preferences, key: key) {
            preferences.setValue(false, forKey: key)
            if canGet(preferences, key: key), let now = preferences.value(forKey: key) as? Bool, !now {
                applied.append(key)
            } else if !canGet(preferences, key: key) {
                applied.append(key + "(unverified)")
            }
        }
        return applied
    }

    /// Logs which keys this macOS accepts. Called once at launch.
    static func logSoftwareRenderingSupport() {
        let probe = WKPreferences()
        let applied = applySoftwareRendering(probe)
        NSLog(
            "Wyvern hardware acceleration %@; software-rendering keys that take effect: %@",
            hardwareAcceleration ? "on" : "off",
            applied.isEmpty ? "none" : applied.joined(separator: ", ")
        )
    }

    /// Double-rAF first-paint probe. Installed only when `--wyvern-bench` is on.
    static func installBenchHooks(on configuration: WKWebViewConfiguration, handler: WKScriptMessageHandler) {
        guard BenchMarks.isEnabled else { return }
        let controller = configuration.userContentController
        controller.removeScriptMessageHandler(forName: "wyvernBench")
        controller.add(handler, name: "wyvernBench")
        installBenchScript(on: controller)
    }

    static func installBenchScript(on controller: WKUserContentController) {
        guard BenchMarks.isEnabled else { return }
        let source = """
        (function(){
          function ping(){
            try { window.webkit.messageHandlers.wyvernBench.postMessage('first-paint'); } catch (e) {}
          }
          requestAnimationFrame(function(){ requestAnimationFrame(ping); });
        })();
        """
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    init(configuration: WKWebViewConfiguration, host: BrowserTabHost, surface: TabSurface = .newTab) {
        let handler = BenchPaintHandler()
        Self.installBenchHooks(on: configuration, handler: handler)
        let probe = BlockListProbeHandler()
        BlockListProbe.installHandler(on: configuration.userContentController, handler: probe)
        benchHandler = handler
        probeHandler = probe
        // Popup configurations come from WebKit. Every page web view gets the same defaults,
        // including the Safari application name (popups, tiles, and restored tabs all pass here).
        WebContentDefaults.apply(to: configuration.preferences)
        SafariUserAgent.apply(to: configuration)
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.host = host
        self.surface = surface
        super.init()
        handler.owner = self
        probe.owner = self
        BenchMarks.emitOnce("web-view-created")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // No context-menu hook. WebKit adds Inspect Element when developer extras are on.
        webView.allowsBackForwardNavigationGestures = true
        if surface != .web {
            applySurface()
        }
        applyInspectability()
        applyPageMetrics(fontSize: Self.defaultFontSize, zoomPercent: Self.defaultZoomPercent)
        installCookieRules()
        cookieObserver = NotificationCenter.default.addObserver(
            forName: .wyvernCookieRulesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.installCookieRules()
            }
        }
        developerToolsObserver = NotificationCenter.default.addObserver(
            forName: .wyvernDeveloperToolsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let enabled = DeveloperTools.enabled(from: note)
            Task { @MainActor in
                if let enabled {
                    BrowserTab.developerToolsEnabled = enabled
                }
                self?.applyInspectability()
            }
        }
        blockRulesObserver = NotificationCenter.default.addObserver(
            forName: .wyvernBlockRulesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.installCookieRules()
            }
        }
        startObserving()
    }

    /// Matches `isInspectable` and `developerExtrasEnabled` to the surface and the setting.
    /// `isInspectable` is the documented switch on macOS 13.3 and later. The preference key
    /// is written only when `WKPreferences` responds to a setter, so an unknown key cannot raise.
    func applyInspectability() {
        guard !didShutdown else { return }
        let enabled = DeveloperTools.shouldBeInspectable(
            surface: WebContentSurface(surface),
            setting: Self.developerToolsEnabled
        )
        if #available(macOS 13.3, *) {
            webView.isInspectable = enabled
        }
        WebInspectorPreferences.setDeveloperExtrasEnabled(enabled, on: webView.configuration.preferences)
    }

    /// Zoom uses `pageZoom`. Font size uses `_setTextZoomFactor:` when WebKit implements it,
    /// and a document-start user script otherwise.
    func applyPageMetrics(fontSize: Int, zoomPercent: Int) {
        let points = min(24, max(12, fontSize))
        let percent = min(200, max(50, zoomPercent))
        webView.pageZoom = CGFloat(percent) / 100
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if Self.supportsTextZoom(webView) {
            Self.setTextZoomFactor(webView, CGFloat(points) / 16)
        } else {
            controller.addUserScript(Self.fontSizeScript(points: points))
            if surface == .web {
                let source = "document.documentElement && (document.documentElement.style.fontSize='\(points)px')"
                webView.evaluateJavaScript(source) { _, _ in }
            }
        }
        Self.installBenchScript(on: controller)
        BlockListProbe.installScript(on: controller)
    }

    func installCookieRules() {
        guard !didShutdown else { return }
        CookiePolicyController.shared.install(on: webView.configuration)
    }

    static func fontSizeScript(points: Int) -> WKUserScript {
        let source = """
        (function(){
          var px = "\(points)px";
          function apply(){
            var root = document.documentElement;
            if (!root) { return; }
            root.style.fontSize = px;
          }
          apply();
          document.addEventListener("DOMContentLoaded", apply);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static func supportsTextZoom(_ webView: WKWebView) -> Bool {
        webView.responds(to: NSSelectorFromString("_setTextZoomFactor:"))
    }

    static func setTextZoomFactor(_ webView: WKWebView, _ factor: CGFloat) {
        let selector = NSSelectorFromString("_setTextZoomFactor:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        let setter = unsafeBitCast(webView.method(for: selector), to: Setter.self)
        setter(webView, selector, factor)
    }

    func load(url: URL, userTypedFile: Bool) {
        isShowingErrorPage = false
        errorPageNavigation = nil
        errorPageStartPending = false
        resetBlockedRequestCount()
        cancelPendingMedia()
        if let page = InternalPage.parse(url) {
            userInitiatedNavigation = false
            showingTypedTarget = false
            show(page)
            return
        }
        surface = .web
        applyInspectability()
        faviconGeneration += 1
        favicon = nil
        displayedURL = url
        showingTypedTarget = true
        isLoading = true
        estimatedProgress = 0
        userInitiatedNavigation = true
        if let hostName = url.host, !hostName.isEmpty {
            title = hostName
        }
        host?.browserTabDidUpdate(self, progressOnly: false)
        if userTypedFile, url.scheme?.lowercased() == "file" {
            permittedFileURL = url
            let accessRoot = url.deletingLastPathComponent()
            currentNavigation = webView.loadFileURL(url, allowingReadAccessTo: accessRoot)
            return
        }
        permittedFileURL = nil
        // Every typed load goes to the network. A repeat of the same attachment URL must reach
        // the server again so WebKit starts a fresh WKDownload instead of reusing a cached reply.
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        currentNavigation = webView.load(request)
    }

    func show(_ page: InternalPage) {
        resetBlockedRequestCount()
        cancelPendingMedia()
        surface = page == .bookmarks ? .bookmarks : .newTab
        faviconGeneration += 1
        favicon = nil
        applySurface()
        applyInspectability()
        host?.browserTabDidUpdate(self, progressOnly: false)
        host?.browserTabDidSettle(self)
        webView.stopLoading()
    }

    private func applySurface() {
        switch surface {
        case .bookmarks:
            title = "Bookmarks"
            displayedURL = InternalPage.bookmarks.url
        case .newTab:
            title = "New Tab"
            displayedURL = nil
        case .web:
            return
        }
        canGoBack = false
        canGoForward = false
        isLoading = false
        estimatedProgress = 0
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        cancelPendingMedia()
        faviconGeneration += 1
        for observation in observations {
            observation.invalidate()
        }
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if let cookieObserver {
            NotificationCenter.default.removeObserver(cookieObserver)
            self.cookieObserver = nil
        }
        if let developerToolsObserver {
            NotificationCenter.default.removeObserver(developerToolsObserver)
            self.developerToolsObserver = nil
        }
        if let blockRulesObserver {
            NotificationCenter.default.removeObserver(blockRulesObserver)
            self.blockRulesObserver = nil
        }
        if BenchMarks.isEnabled {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "wyvernBench")
        }
        BlockListProbe.removeHandler(from: webView.configuration.userContentController)
        ContentRuleCoordinator.shared.forget(webView.configuration)
        webView.stopLoading()
        webView.removeFromSuperview()
        benchHandler.owner = nil
        probeHandler.owner = nil
        host = nil
    }

    private func startObserving() {
        // WebKit publishes these properties on the main thread. Tokens are stored on the
        // tab and invalidated in shutdown so the web view does not retain the tab.
        observations.append(webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pullFromWebView() }
        })
        observations.append(webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pullFromWebView() }
        })
        observations.append(webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pullFromWebView() }
        })
        observations.append(webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pullFromWebView() }
        })
        observations.append(webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pullFromWebView() }
        })
        observations.append(webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pullFromWebView() }
        })
        // WebKit takes the web view into its own window for element fullscreen and puts it back
        // on exit. The host re-pins it then, so the tile or solo layout comes back as it was.
        observations.append(webView.observe(\.fullscreenState, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self, !self.didShutdown, webView.fullscreenState == .notInFullscreen else { return }
                self.host?.browserTabDidExitElementFullscreen(self)
            }
        })
    }

    private func pullFromWebView() {
        guard !didShutdown, surface == .web else { return }
        if isShowingErrorPage {
            // The error document has no committed URL. Keep the failing address and title.
            let newBack = webView.canGoBack
            let newForward = webView.canGoForward
            let newLoading = webView.isLoading
            let newProgress = webView.estimatedProgress
            let barsChanged = newBack != canGoBack
                || newForward != canGoForward
                || newLoading != isLoading
            let progressChanged = newProgress != estimatedProgress
            canGoBack = newBack
            canGoForward = newForward
            isLoading = newLoading
            estimatedProgress = newProgress
            if barsChanged || progressChanged {
                host?.browserTabDidUpdate(self, progressOnly: progressChanged && !barsChanged)
            }
            return
        }
        let rawTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newTitle = rawTitle.isEmpty ? "New Tab" : rawTitle
        let newURL = visibleURL(candidate: webView.url, loading: webView.isLoading)
        let previousHost = displayedURL?.host
        let newBack = webView.canGoBack
        let newForward = webView.canGoForward
        let newLoading = webView.isLoading
        let newProgress = webView.estimatedProgress
        let barsChanged = newTitle != title
            || newURL != displayedURL
            || newBack != canGoBack
            || newForward != canGoForward
            || newLoading != isLoading
        let progressChanged = newProgress != estimatedProgress
        title = newTitle
        displayedURL = newURL
        canGoBack = newBack
        canGoForward = newForward
        isLoading = newLoading
        estimatedProgress = newProgress
        if barsChanged || progressChanged {
            host?.browserTabDidUpdate(self, progressOnly: progressChanged && !barsChanged)
        }
        if previousHost != newURL?.host {
            if let pending = pendingMediaOriginHost, pending != newURL?.host {
                cancelPendingMedia()
            }
            host?.browserTab(self, hostDidChange: newURL?.host)
        }
    }

    /// While a provisional load is in flight the document is still the previous page.
    /// A page-started navigation keeps that page's URL until `didCommit`.
    private func visibleURL(candidate: URL?, loading: Bool) -> URL? {
        switch AddressCommit.choice(showingTypedTarget: showingTypedTarget, loading: loading) {
        case .keepDisplayed:
            return displayedURL
        case .keepCommitted:
            return committedURL ?? displayedURL
        case .adoptCandidate:
            committedURL = candidate
            return candidate
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let isErrorDocument = navigation === errorPageNavigation || errorPageStartPending
        errorPageStartPending = false
        if isErrorDocument == false {
            isShowingErrorPage = false
            errorPageNavigation = nil
        }
        currentNavigation = navigation
        if mainFrameStartsPending > 0 {
            mainFrameStartsPending -= 1
            resetBlockedRequestCount()
        }
        if BenchMarks.isEnabled {
            benchDidFinish = false
            benchDidRAF = false
            BenchMarks.emit("navigation-started")
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        clearUserInitiated(navigation)
        cancelPendingMedia()
        showingTypedTarget = false
        if webView.url?.scheme?.lowercased() != "file" {
            permittedFileURL = nil
        }
        if surface == .web, isShowingErrorPage == false {
            committedURL = webView.url
            displayedURL = webView.url
            host?.browserTabDidUpdate(self, progressOnly: false)
        }
        applyKVMMediaPolicy(newDocument: true)
    }

    /// Main frame only: `evaluateJavaScript` runs in the page, not in a subframe.
    /// A new document does not run the undo script, so a normal site is not touched.
    func applyKVMMediaPolicy(newDocument: Bool) {
        guard didShutdown == false else { return }
        let pageURL = surface == .web ? (webView.url ?? displayedURL) : nil
        let enabled = pageURL.map { Self.kvmSites.contains($0) } ?? false
        applyKVMScheduling(enabled: enabled)
        if newDocument {
            kvmMediaInstalled = false
        }
        if enabled {
            webView.evaluateJavaScript(KVMMediaScript.source) { _, _ in }
            kvmMediaInstalled = true
        } else if kvmMediaInstalled {
            webView.evaluateJavaScript(KVMMediaScript.undo) { _, _ in }
            kvmMediaInstalled = false
        }
    }

    /// macOS 14+ keeps a KVM tab scheduled while it is occluded. Leaving the origin restores `.suspend`.
    /// Pages that were never a KVM origin are not written, so their scheduling stays at the WebKit default.
    private func applyKVMScheduling(enabled: Bool) {
        guard #available(macOS 14.0, *) else { return }
        if enabled == kvmInactivePolicyIsNone { return }
        kvmInactivePolicyIsNone = enabled
        let policy: WKPreferences.InactiveSchedulingPolicy = enabled
            ? WKPreferences.InactiveSchedulingPolicy.none
            : WKPreferences.InactiveSchedulingPolicy.suspend
        webView.configuration.preferences.inactiveSchedulingPolicy = policy
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        clearUserInitiated(navigation)
        if BenchMarks.isEnabled {
            BenchMarks.emit("navigation-finished")
            benchDidFinish = true
            webView.layoutSubtreeIfNeeded()
            webView.displayIfNeeded()
            emitFirstPaintIfReady()
            // No synthetic fallback: if the page never reports its double-rAF paint, the sample stays missing (honest metric).
        }
        guard surface == .web else { return }
        pullFromWebView()
        scheduleFaviconFetch()
        host?.browserTabDidSettle(self)
        applyKVMMediaPolicy(newDocument: false)
    }

    func absorbProbeURLs(_ urls: [String]) {
        let added = BlockListController.shared.consume(urls: urls, seen: &probeSeen)
        guard added > 0 else { return }
        blockedRequestCount += added
        host?.browserTabDidUpdate(self, progressOnly: false)
    }

    private func resetBlockedRequestCount() {
        guard blockedRequestCount != 0 || probeSeen.isEmpty == false else { return }
        blockedRequestCount = 0
        probeSeen.removeAll()
        host?.browserTabDidUpdate(self, progressOnly: false)
    }

    func handleBenchPaintMessage() {
        guard BenchMarks.isEnabled else { return }
        benchDidRAF = true
        emitFirstPaintIfReady()
    }

    private func emitFirstPaintIfReady() {
        guard benchDidFinish, benchDidRAF else { return }
        BenchMarks.emitOnce("first-paint")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        presentLoadFailure(navigation: navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        presentLoadFailure(navigation: navigation, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping AuthChallengeHandler
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var evaluateError: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &evaluateError)
        if trusted {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        let hostName = space.host
        let port: Int? = space.port > 0 ? space.port : nil
        if let key = ServerTrustAllowlist.key(host: hostName, port: port, trust: trust),
           serverTrustAllowlist.contains(key) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        let info = ServerTrustCertificateInfo.from(trust: trust)
        let displayHost: String = {
            if let port, port != 443 {
                return "\(hostName):\(port)"
            }
            return hostName.isEmpty ? "this site" : hostName
        }()

        let alert = NSAlert()
        alert.messageText = "This connection is not private"
        alert.informativeText = info.alertBody(hostDisplay: displayHost)
        alert.alertStyle = .warning
        // First button is the default. Go Back does not add the certificate to the allowlist.
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Continue")
        if let goBack = alert.buttons.first {
            goBack.keyEquivalent = "\u{1b}"
        }

        let finish: (Bool) -> Void = { [weak self] proceed in
            guard let self else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            if proceed {
                if let key = ServerTrustAllowlist.key(host: hostName, port: port, trust: trust) {
                    self.serverTrustAllowlist.allow(key)
                }
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        if let window = webView.window {
            alert.beginSheetModal(for: window) { response in
                finish(response == .alertSecondButtonReturn)
            }
        } else {
            let response = alert.runModal()
            finish(response == .alertSecondButtonReturn)
        }
    }

    private func presentLoadFailure(navigation: WKNavigation?, error: Error) {
        if let navigation, let errorPageNavigation, navigation === errorPageNavigation {
            restoreCommittedURL(navigation)
            return
        }
        // A newer navigation already owns the web view. A late cancel must not replace it.
        if let navigation, let currentNavigation, navigation !== currentNavigation {
            return
        }
        restoreCommittedURL(navigation)
        guard surface == .web else { return }
        if isShowingErrorPage {
            return
        }
        let copy = LoadFailureCopy.from(error: error)
        let failing = LoadFailureCopy.failingURL(from: error) ?? displayedURL ?? committedURL
        // Skip a blank cancel with no URL (common during rapid reloads).
        if copy.preferSilent, failing == nil {
            return
        }
        let html = LoadFailureCopy.htmlDocument(copy: copy, failingURL: failing)
        isShowingErrorPage = true
        // Set before loadHTMLString. WebKit can call didStart before that call returns,
        // and the navigation object is not assigned until it does.
        errorPageStartPending = true
        title = copy.title
        if let failing {
            displayedURL = failing
        }
        errorPageNavigation = webView.loadHTMLString(html, baseURL: nil)
        if errorPageNavigation != nil {
            errorPageStartPending = false
        }
        host?.browserTabDidUpdate(self, progressOnly: false)
    }

    private func restoreCommittedURL(_ navigation: WKNavigation?) {
        clearUserInitiated(navigation)
        showingTypedTarget = false
        guard surface == .web else { return }
        displayedURL = committedURL ?? webView.url
        host?.browserTabDidUpdate(self, progressOnly: false)
    }

    private func clearUserInitiated(_ navigation: WKNavigation?) {
        guard let navigation else {
            userInitiatedNavigation = false
            return
        }
        if navigation === currentNavigation {
            userInitiatedNavigation = false
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.browserTabDidRequestClose(self)
    }

    func cancelPendingMedia() {
        let cancel = pendingMediaCancel
        pendingMediaCancel = nil
        pendingMediaOriginHost = nil
        if cancel != nil {
            host?.browserTabDidCancelMediaPrompt(self)
        }
        cancel?()
    }

    // Location and notifications: WKWebView has no public permission prompt.
    // The Site permissions choice is stored and denied by default. This delegate
    // does not grant either one.
    @available(macOS 12.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping MediaCaptureDecisionHandler
    ) {
        _ = webView
        let key = MediaPermissionPolicy.originKey(scheme: origin.`protocol`, host: origin.host, port: origin.port)
        if !MediaPermissionPolicy.allowsFrame(isMainFrame: frame.isMainFrame, requesterOrigin: key, topLevelURL: webView.url) {
            decisionHandler(.deny)
            return
        }
        let kind: MediaCaptureKind
        switch type {
        case .camera:
            kind = .camera
        case .microphone:
            kind = .microphone
        case .cameraAndMicrophone:
            kind = .both
        @unknown default:
            kind = .both
        }
        cancelPendingMedia()
        guard !didShutdown else {
            decisionHandler(.deny)
            return
        }
        var finished = false
        let finish: (Bool) -> Void = { grant in
            guard !finished else { return }
            finished = true
            self.pendingMediaCancel = nil
            self.pendingMediaOriginHost = nil
            decisionHandler(grant ? .grant : .deny)
        }
        pendingMediaOriginHost = origin.host
        pendingMediaCancel = { finish(false) }
        guard let host else {
            finish(false)
            return
        }
        host.browserTab(self, decideMediaCapture: key, kind: kind) { [weak self] grant in
            guard let self, !self.didShutdown else {
                finish(false)
                return
            }
            finish(grant)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // A real new window has no target frame. Framed navigations stay in this view.
        guard navigationAction.targetFrame == nil else { return nil }
        // Block is the only stored choice that refuses the new view. Ask stays on this path.
        if popupBlocked(navigationAction) {
            return nil
        }
        let now = Date()
        let burst = PopupFloodPolicy.admit(recent: popupTimes, now: now)
        popupTimes = burst.retained
        if !burst.allow {
            return nil
        }
        // Use the configuration WebKit passed in. Do not substitute the default one.
        WebContentDefaults.apply(to: configuration.preferences)
        applyAutoplay(to: configuration, url: navigationAction.request.url)
        return host?.browserTab(self, createWebViewWith: configuration)
    }

    private func popupBlocked(_ navigationAction: WKNavigationAction) -> Bool {
        let origin = navigationAction.sourceFrame.securityOrigin
        guard !origin.host.isEmpty, let host else { return false }
        let key = MediaPermissionPolicy.originKey(scheme: origin.`protocol`, host: origin.host, port: origin.port)
        let choice = host.browserTab(self, permissionChoice: key, kind: .popups)
        return !SitePermissionPolicy.allowsPopup(choice)
    }

    private func applyAutoplay(to configuration: WKWebViewConfiguration, url: URL?) {
        guard let host, let url, let key = SitePermissionPolicy.originKey(for: url) else { return }
        let choice = host.browserTab(self, permissionChoice: key, kind: .autoplay)
        Self.applyPlaybackOverride(SitePermissionPolicy.playbackOverride(choice), to: configuration)
    }

    /// Ask does not write the property, so a new web view keeps the system default.
    static func applyPlaybackOverride(_ override: SitePlaybackOverride, to configuration: WKWebViewConfiguration) {
        switch override {
        case .leaveDefault:
            return
        case .requireUserAction:
            configuration.mediaTypesRequiringUserActionForPlayback = .all
        case .allowWithoutUserAction:
            configuration.mediaTypesRequiringUserActionForPlayback = []
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping NavigationDecisionHandler
    ) {
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true {
            userInitiatedNavigation = true
            // Drop the previous navigation identity so its late failure cannot clear this flag.
            currentNavigation = nil
        }
        if navigationAction.shouldPerformDownload {
            // A nil target frame is not the main frame. Subframe noise never starts a download.
            let knownMain = navigationAction.targetFrame?.isMainFrame == true
            if knownMain {
                decisionHandler(.download, preferences)
            } else {
                decisionHandler(.cancel, preferences)
            }
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        // The frame that asked, not the top document. An https iframe in a local
        // page must not inherit that page's file grant.
        // WebKit passes a nil source frame for loads the app starts itself, although the
        // Swift type is non-optional. Reading it through KVC keeps that case from trapping.
        let sourceFrame = navigationAction.value(forKey: "sourceFrame") as? WKFrameInfo
        let sourceURL = sourceFrame?.request.url ?? webView.url
        if let page = InternalPage.parse(url) {
            decisionHandler(.cancel, preferences)
            if mainFrame {
                Task { @MainActor [weak self] in
                    self?.show(page)
                }
            }
            return
        }
        let decision = NavigationPolicy.decide(
            NavigationRequest(
                url: url,
                isMainFrame: mainFrame,
                userTypedFileURL: permittedFileURL,
                currentPageURL: sourceURL
            )
        )
        switch decision {
        case .allow:
            if mainFrame {
                mainFrameStartsPending += 1
            }
            decisionHandler(.allow, preferences)
        case .cancel:
            decisionHandler(.cancel, preferences)
        case .denyFile:
            decisionHandler(.cancel, preferences)
            if mainFrame {
                host?.browserTabDeniedFile(self)
            }
        case .confirmExternal:
            decisionHandler(.cancel, preferences)
            if mainFrame {
                host?.browserTab(self, confirmExternal: url)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping ResponseDecisionHandler
    ) {
        let http = navigationResponse.response as? HTTPURLResponse
        let input = ResponseInput(
            isMainFrame: navigationResponse.isForMainFrame,
            canShowMIMEType: navigationResponse.canShowMIMEType,
            mimeType: navigationResponse.response.mimeType ?? "",
            statusCode: http?.statusCode ?? 0,
            contentDisposition: http?.value(forHTTPHeaderField: "Content-Disposition"),
            userInitiated: userInitiatedNavigation
        )
        switch NavigationPolicy.decideResponse(input) {
        case .allow:
            decisionHandler(.allow)
        case .cancelSilently:
            decisionHandler(.cancel)
        case .download:
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        _ = webView
        _ = navigationAction
        DownloadManager.shared.adopt(download, userInitiated: userInitiatedNavigation)
        userInitiatedNavigation = false
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        _ = webView
        _ = navigationResponse
        DownloadManager.shared.adopt(download, userInitiated: userInitiatedNavigation)
        userInitiatedNavigation = false
    }

    private func scheduleFaviconFetch() {
        faviconGeneration += 1
        let generation = faviconGeneration
        guard let pageURL = webView.url else { return }
        Task { [weak self] in
            guard let self else { return }
            let href: String?
            do {
                let result: Any? = try await self.webView.evaluateJavaScript(Self.iconScript)
                href = result as? String
            } catch {
                href = nil
            }
            guard self.faviconGeneration == generation else { return }
            await self.applyFavicon(pageURL: pageURL, href: href, generation: generation)
        }
    }

    private func applyFavicon(pageURL: URL, href: String?, generation: Int) async {
        guard surface == .web, faviconGeneration == generation else { return }
        guard let primary = FaviconPolicy.iconURL(pageURL: pageURL, linkHref: href) else {
            favicon = nil
            host?.browserTabDidUpdate(self, progressOnly: false)
            return
        }
        var image = await FaviconService.shared.image(for: primary)
        if image == nil,
           let hostName = pageURL.host,
           let fallback = FaviconPolicy.fallback(host: hostName),
           fallback != primary {
            image = await FaviconService.shared.image(for: fallback)
        }
        guard faviconGeneration == generation else { return }
        favicon = image
        host?.browserTabDidUpdate(self, progressOnly: false)
    }

    /// First `link` whose `rel` contains the token `icon` (CSS `rel~=icon`).
    private static let iconScript = """
    (function() {
      var nodes = document.getElementsByTagName('link');
      for (var i = 0; i < nodes.length; i++) {
        var rel = (nodes[i].getAttribute('rel') || '').toLowerCase();
        var parts = rel.split(/\\s+/);
        for (var j = 0; j < parts.length; j++) {
          if (parts[j] === 'icon') {
            return nodes[i].getAttribute('href') || '';
          }
        }
      }
      return '';
    })()
    """
}

/// Receives the bench-mode double-rAF message. Private WK paint APIs are not used.
@MainActor
final class BenchPaintHandler: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserTab?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        _ = userContentController
        guard message.name == "wyvernBench" else { return }
        if Thread.isMainThread {
            owner?.handleBenchPaintMessage()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.owner?.handleBenchPaintMessage()
            }
        }
    }
}
