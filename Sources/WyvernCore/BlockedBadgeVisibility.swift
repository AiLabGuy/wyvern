// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// When the toolbar blocked-count badge is shown, and the width written on its constraint.
public enum BlockedBadgeVisibility {
    /// Visible on every http/https web page while blocking is on or Show Blocked Count is on.
    /// Hidden on terminal panes, non-web surfaces, and non-http(s) URLs.
    public static func shouldShow(
        blockingEnabled: Bool,
        showBlockedCount: Bool,
        isTerminal: Bool,
        isWebSurface: Bool,
        scheme: String?
    ) -> Bool {
        guard blockingEnabled || showBlockedCount else { return false }
        if isTerminal { return false }
        guard isWebSurface else { return false }
        let normalized = scheme?.lowercased()
        return normalized == "http" || normalized == "https"
    }

    /// Width for the badge's Autolayout constant. Set this before un-hiding in an
    /// `NSStackView` with `detachesHiddenViews`, so the view is not reattached at zero width.
    public static func constraintWidth(visible: Bool, preferredWidth: Double) -> Double {
        visible ? max(preferredWidth, 0) : 0
    }
}
