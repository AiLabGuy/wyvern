// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Preferences every page web view starts with, including popups WebKit configures for us.
///
/// `WKPreferences.isElementFullscreenEnabled` is off by default on macOS. Without it the page's
/// Fullscreen API reports `document.fullscreenEnabled == false`, so the fullscreen button on video
/// players (YouTube, X, and embeds with `allowfullscreen`) does nothing.
public enum WebContentDefaults {
    /// The HTML Fullscreen API (element fullscreen) is on for every page.
    public static let elementFullscreenEnabled = true
    /// Unsolicited scripted popups stay blocked. A user gesture still reaches createWebViewWith.
    public static let javaScriptCanOpenWindowsAutomatically = false

    #if canImport(WebKit)
    @MainActor
    public static func apply(to preferences: WKPreferences) {
        preferences.javaScriptCanOpenWindowsAutomatically = javaScriptCanOpenWindowsAutomatically
        preferences.isElementFullscreenEnabled = elementFullscreenEnabled
    }
    #endif
}

/// Whether a host view may take a web view into itself.
///
/// While a page is in element fullscreen, WebKit moves the web view into its own fullscreen
/// window and leaves a placeholder behind. Re-adding the web view to a tile or the solo page
/// container during that time pulls it out of the fullscreen window and removes the placeholder
/// WebKit needs to put it back. Hosts wait until fullscreen ends and then re-pin it.
public enum FullscreenHostingPolicy {
    public static func shouldMove(isChildOfTarget: Bool, inElementFullscreen: Bool) -> Bool {
        if inElementFullscreen { return false }
        return HostedViewPlacement.shouldMove(isChildOfTarget: isChildOfTarget)
    }

    /// After fullscreen, a view back in its host must be pinned again: WebKit restores the
    /// frame, but constraints that were dropped when it left may not all come back.
    public static func shouldRepin(isChildOfTarget: Bool, pinnedEdges: Int, inElementFullscreen: Bool) -> Bool {
        !inElementFullscreen && isChildOfTarget && pinnedEdges < 4
    }
}
