// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit
import os
import WebKit

/// Private WebKit inspector SPI. Every selector is checked with `responds(to:)` before use.
/// A missing selector is skipped. Nothing here raises for an unknown key.
///
/// Hosting sets the source web view's `_inspectorAttachmentView` to our container, then
/// `connect` / `show` (when present) / `attach`. `show` is not in the fetched `_WKInspector.h`;
/// it is called only when the object responds. After 1.5 seconds, hosted mode requires both
/// `isVisible` and the frontend view inside the container. Otherwise the inspector is detached
/// and its window is kept as a companion of the DevTools tab.
///
/// Dock-button CSS is fragile. The class names were not verified against the inspector DOM
/// and can change between OS releases. The injection is guarded and ignored when the frontend
/// web view is missing.
@MainActor
final class WebInspectorHost: NSObject {
    static let log = OSLog(subsystem: AppInfo.bundleIdentifier, category: "devtools")

    /// Placeholder selectors. Not verified against Web Inspector's frontend DOM.
    static let dockButtonCSS = """
    (function(){
      var css = '.dock-to-bottom,.dock-to-right,.dock-to-left,.undock{display:none!important}';
      var style = document.createElement('style');
      style.setAttribute('data-wyvern', 'devtools-dock');
      style.textContent = css;
      var parent = document.head || document.documentElement;
      if (parent) parent.appendChild(style);
    })();
    """

    private weak var webView: WKWebView?
    private weak var container: NSView?
    private var verifyTimer: Timer?
    private var resolved = false
    private var companion: NSWindow?
    private(set) var mode: String?
    /// True when WebKit returned no inspector object. Hosted and detached paths both failed.
    private(set) var failedEntirely = false

    /// Fired when WebKit loads the frontend, including Inspect Element with no DevTools tab yet.
    var onFrontendLoaded: (() -> Void)?
    var onMode: ((String) -> Void)?

    /// Points the page at a sized standby view so Inspect Element can dock before a tab exists.
    func prepareStandby(webView: WKWebView, container: NSView) {
        self.webView = webView
        self.container = container
        _ = setAttachment(container)
        setDelegate()
    }

    /// Docks the inspector into `container`. Resolves to `hosted` or falls back to `window`.
    func showHosted(in container: NSView, webView: WKWebView) {
        self.webView = webView
        self.container = container
        resolved = false
        failedEntirely = false
        mode = nil
        verifyTimer?.invalidate()
        // b206: hosting inside the pane flashed and never opened. Default to WebKit's own
        // inspector window. Set WYVERN_DEVTOOLS_HOSTED=1 to try the in-pane host again.
        if ProcessInfo.processInfo.environment["WYVERN_DEVTOOLS_HOSTED"] != "1" {
            setDelegate()
            guard let inspector = inspectorObject() else {
                failedEntirely = true
                fallbackToWindow()
                return
            }
            invoke(inspector, "connect")
            invoke(inspector, "show")
            invoke(inspector, "detach")
            // The frontend window can appear a moment after `detach`.
            windowRetries = 0
            adoptWindowSoon()
            return
        }
        guard setAttachment(container) else {
            fallbackToWindow()
            return
        }
        setDelegate()
        guard let inspector = inspectorObject() else {
            failedEntirely = true
            fallbackToWindow()
            return
        }
        let connected = invoke(inspector, "connect")
        let shown = invoke(inspector, "show")
        let attached = invoke(inspector, "attach")
        if !connected, !shown, !attached {
            fallbackToWindow()
            return
        }
        if hosted(inspector) {
            resolve("hosted")
            return
        }
        scheduleVerify()
    }

    func toggleElementSelection() {
        guard let inspector = inspectorObject() else { return }
        invoke(inspector, "toggleElementSelection")
    }

    /// Opens the console when WebKit implements `showConsole`. Returns false when it does not.
    @discardableResult
    func focusConsole() -> Bool {
        guard let inspector = inspectorObject() else { return false }
        return invoke(inspector, "showConsole")
    }

    /// Hides the inspector when WebKit implements `hide`, so a reopen within 30 seconds can restore it.
    /// `close` is used only when `hide` is missing. Panel restoration then depends on WebKit.
    func suspend() {
        verifyTimer?.invalidate()
        guard let inspector = inspectorObject() else { return }
        if !invoke(inspector, "hide") {
            invoke(inspector, "close")
        }
    }

    /// Explicit shutdown. Not called from `deinit`.
    func shutdown() {
        verifyTimer?.invalidate()
        verifyTimer = nil
        onFrontendLoaded = nil
        onMode = nil
        if let companion {
            companion.parent?.removeChildWindow(companion)
            companion.close()
        }
        companion = nil
        if let inspector = inspectorObject() {
            if !invoke(inspector, "close") {
                invoke(inspector, "hide")
            }
        }
        container = nil
        webView = nil
    }

    /// No page web view. Logs the window path so a missing page is visible to tests.
    func failHosted() {
        failedEntirely = true
        fallbackToWindow()
    }

    /// The container moved to another window. The detached inspector window follows it.
    func reparentCompanion() {
        guard let companion else { return }
        guard let parent = container?.window, companion !== parent else { return }
        companion.parent?.removeChildWindow(companion)
        if companion.parent !== parent {
            parent.addChildWindow(companion, ordered: .above)
        }
    }

    func orderCompanionFront() {
        if companion == nil {
            adoptCompanion()
        }
        companion?.makeKeyAndOrderFront(nil)
    }

    static func isBeingInspected(_ webView: WKWebView) -> Bool {
        boolFlag("_isBeingInspected", on: webView)
    }

    @objc(inspectorFrontendLoaded:)
    func inspectorFrontendLoaded(_ inspector: NSObject) {
        injectDockCSS(into: inspector)
        onFrontendLoaded?()
        if !resolved, hosted(inspector) {
            resolve("hosted")
        }
    }

    @objc(inspector:openURLExternally:)
    func inspector(_ inspector: NSObject, openURLExternally url: NSURL) {
        _ = inspector
        let target = url as URL
        // The inspector frontend is a web view. Only ordinary web URLs leave the app.
        guard ExternalLaunchPolicy.canOpenFromInspector(target) else { return }
        NSWorkspace.shared.open(target)
    }

    private func hosted(_ inspector: NSObject) -> Bool {
        inspectorIsVisible(inspector) && frontendIsInsideContainer(inspector)
    }

    private func scheduleVerify() {
        verifyTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishVerification()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        verifyTimer = timer
    }

    private func finishVerification() {
        guard !resolved else { return }
        if let inspector = inspectorObject(), hosted(inspector) {
            resolve("hosted")
            return
        }
        fallbackToWindow()
    }

    private var windowRetries = 0

    private func adoptWindowSoon() {
        adoptCompanion()
        if companion != nil || windowRetries >= 10 {
            resolve("window")
            return
        }
        windowRetries += 1
        let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.adoptWindowSoon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        verifyTimer = timer
    }

    private func fallbackToWindow() {
        guard !resolved else { return }
        verifyTimer?.invalidate()
        if let inspector = inspectorObject() {
            invoke(inspector, "detach")
        }
        adoptCompanion()
        resolve("window")
    }

    private func resolve(_ mode: String) {
        guard !resolved else { return }
        resolved = true
        verifyTimer?.invalidate()
        verifyTimer = nil
        self.mode = mode
        let line = "WYVERN_DEVTOOLS_MODE=\(mode)\n"
        fputs(line, stderr)
        fflush(stderr)
        os_log("%{public}@", log: Self.log, type: .info, line)
        onMode?(mode)
    }

    private func adoptCompanion() {
        guard let inspector = inspectorObject(),
              let frontend = frontendView(from: inspector),
              let window = frontend.window else {
            return
        }
        if window === container?.window {
            return
        }
        companion = window
        if let parent = container?.window, window.parent !== parent {
            parent.addChildWindow(window, ordered: .above)
        }
    }

    /// `setValue(_:forKey:)` raises for a key WebKit does not expose as KVC.
    /// `perform` after `responds(to:)` does not.
    @discardableResult
    private func setAttachment(_ view: NSView) -> Bool {
        guard let webView else { return false }
        let setter = NSSelectorFromString("_setInspectorAttachmentView:")
        guard webView.responds(to: setter) else { return false }
        _ = webView.perform(setter, with: view)
        return true
    }

    private func setDelegate() {
        guard let inspector = inspectorObject() else { return }
        let setter = NSSelectorFromString("setDelegate:")
        guard inspector.responds(to: setter) else { return }
        _ = inspector.perform(setter, with: self)
    }

    private func inspectorObject() -> NSObject? {
        guard let webView else { return nil }
        return object(named: "_inspector", on: webView) as? NSObject
    }

    @discardableResult
    private func invoke(_ object: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        _ = object.perform(selector)
        return true
    }

    private func inspectorIsVisible(_ inspector: NSObject) -> Bool {
        Self.boolFlag("isVisible", on: inspector)
    }

    private func frontendView(from inspector: NSObject) -> NSView? {
        object(named: "webView", on: inspector) as? NSView
    }

    /// Object-returning SPI. `perform` does not raise when the selector is missing.
    private func object(named name: String, on object: NSObject) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    /// BOOL SPI. A missing selector is false. This does not use KVC, which raises for an unknown key.
    private static func boolFlag(_ name: String, on object: NSObject) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(object.method(for: selector), to: Getter.self)
        return implementation(object, selector)
    }

    private func frontendIsInsideContainer(_ inspector: NSObject) -> Bool {
        guard let container, let frontend = frontendView(from: inspector) else { return false }
        var view: NSView? = frontend
        while let current = view {
            if current === container { return true }
            view = current.superview
        }
        return false
    }

    private func injectDockCSS(into inspector: NSObject) {
        guard let frontend = frontendView(from: inspector) as? WKWebView else { return }
        let script = NSSelectorFromString("evaluateJavaScript:completionHandler:")
        guard frontend.responds(to: script) else { return }
        frontend.evaluateJavaScript(Self.dockButtonCSS, completionHandler: nil)
    }
}
