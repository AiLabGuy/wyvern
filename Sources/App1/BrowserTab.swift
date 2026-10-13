// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import App1Core
import Darwin
import WebKit

// The Xcode 16+ SDK marks these decision handlers MainActor and Sendable.
// The witness must match or WebKit treats the optional method as unimplemented.
#if compiler(>=6)
typealias NavigationDecisionHandler = @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
typealias ResponseDecisionHandler = @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
typealias MediaCaptureDecisionHandler = @MainActor @Sendable (WKPermissionDecision) -> Void
#else
typealias NavigationDecisionHandler = (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
typealias ResponseDecisionHandler = (WKNavigationResponsePolicy) -> Void
typealias MediaCaptureDecisionHandler = (WKPermissionDecision) -> Void
#endif

enum TabSurface: Equatable {
    case web
    case bookmarks
    case newTab
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

    private var observations: [NSKeyValueObservation] = []
    private var didShutdown = false
    private var faviconGeneration = 0
    private var pendingMediaCancel: (() -> Void)?
    private var pendingMediaOriginHost: String?
    private let benchHandler: BenchPaintHandler
    private var benchDidFinish = false
    private var benchDidRAF = false
    private var cookieObserver: NSObjectProtocol?

    static let blankURL: URL = {
        if let url = URL(string: "about:blank") {
            return url
        }
        preconditionFailure("about:blank must be a valid URL")
    }()

    /// Do not set `customUserAgent` or `applicationNameForUserAgent`. The system default stays.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Unsolicited scripted popups stay blocked. A user gesture still reaches
        // createWebViewWith for target=_blank and window.open.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
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

    /// Double-rAF first-paint probe. Installed only when `--app1-bench` is on.
    static func installBenchHooks(on configuration: WKWebViewConfiguration, handler: WKScriptMessageHandler) {
        guard BenchMarks.isEnabled else { return }
        let controller = configuration.userContentController
        controller.removeScriptMessageHandler(forName: "app1Bench")
        controller.add(handler, name: "app1Bench")
        installBenchScript(on: controller)
    }

    static func installBenchScript(on controller: WKUserContentController) {
        guard BenchMarks.isEnabled else { return }
        let source = """
        (function(){
          function ping(){
            try { window.webkit.messageHandlers.app1Bench.postMessage('first-paint'); } catch (e) {}
          }
          requestAnimationFrame(function(){ requestAnimationFrame(ping); });
        })();
        """
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    init(configuration: WKWebViewConfiguration, host: BrowserTabHost, surface: TabSurface = .newTab) {
        let handler = BenchPaintHandler()
        Self.installBenchHooks(on: configuration, handler: handler)
        benchHandler = handler
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.host = host
        self.surface = surface
        super.init()
        handler.owner = self
        BenchMarks.emitOnce("web-view-created")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = false
        }
        if surface != .web {
            applySurface()
        }
        applyPageMetrics(fontSize: Self.defaultFontSize, zoomPercent: Self.defaultZoomPercent)
        installCookieRules()
        cookieObserver = NotificationCenter.default.addObserver(
            forName: .app1CookieRulesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.installCookieRules()
            }
        }
        startObserving()
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
        cancelPendingMedia()
        if let page = InternalPage.parse(url) {
            userInitiatedNavigation = false
            show(page)
            return
        }
        surface = .web
        faviconGeneration += 1
        favicon = nil
        displayedURL = url
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
        cancelPendingMedia()
        surface = page == .bookmarks ? .bookmarks : .newTab
        faviconGeneration += 1
        favicon = nil
        applySurface()
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
        if BenchMarks.isEnabled {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "app1Bench")
        }
        webView.stopLoading()
        webView.removeFromSuperview()
        benchHandler.owner = nil
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
    }

    private func pullFromWebView() {
        guard !didShutdown, surface == .web else { return }
        let rawTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newTitle = rawTitle.isEmpty ? "New Tab" : rawTitle
        let newURL = webView.url
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        currentNavigation = navigation
        if BenchMarks.isEnabled {
            benchDidFinish = false
            benchDidRAF = false
            BenchMarks.emit("navigation-started")
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        clearUserInitiated(navigation)
        cancelPendingMedia()
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
        _ = error
        clearUserInitiated(navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        _ = error
        clearUserInitiated(navigation)
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
        _ = frame
        let key = MediaPermissionPolicy.originKey(scheme: origin.`protocol`, host: origin.host, port: origin.port)
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
        // Use the configuration WebKit passed in. Do not substitute the default one.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
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
                currentPageURL: webView.url
            )
        )
        switch decision {
        case .allow:
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
        guard message.name == "app1Bench" else { return }
        if Thread.isMainThread {
            owner?.handleBenchPaintMessage()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.owner?.handleBenchPaintMessage()
            }
        }
    }
}
