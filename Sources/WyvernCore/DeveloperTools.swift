// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where a page is shown. Only `.web` can be inspected.
/// Settings and terminal are not web views; the policy still refuses them.
public enum WebContentSurface: String, Equatable, Sendable, CaseIterable {
    case web
    case newTab
    case bookmarks
    case settings
    case terminal
}

/// Whether a surface may expose the Web Inspector.
public enum DeveloperTools {
    /// `userInfo` key for `Notification.Name.wyvernDeveloperToolsDidChange`.
    public static let enabledUserInfoKey = "enabled"

    /// Ordinary web content is inspectable only while the setting is on.
    /// The new-tab page, bookmarks, settings, and terminal stay closed.
    public static func shouldBeInspectable(surface: WebContentSurface, setting: Bool) -> Bool {
        setting && surface == .web
    }

    public static func userInfo(enabled: Bool) -> [String: Bool] {
        [enabledUserInfoKey: enabled]
    }

    /// Reads the flag posted with `wyvernDeveloperToolsDidChange`.
    /// A `Bool` stored in `userInfo` can come back as `Bool` or as `NSNumber`.
    public static func enabled(from notification: Notification) -> Bool? {
        guard let raw = notification.userInfo?[enabledUserInfoKey] else { return nil }
        if let flag = raw as? Bool {
            return flag
        }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        return nil
    }
}
