// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Decisions that keep a hosted view from being removed and inserted again.
/// `removeFromSuperview` followed by `addSubview` flashes a WKWebView white.
public enum HostedViewPlacement {
    /// The view is already in the parent that should show it. Do not move it.
    public static func shouldMove(isChildOfTarget: Bool) -> Bool {
        !isChildOfTarget
    }

    /// `addSubview` on a view that is already in its parent removes and reinserts it.
    /// Raise only when it is missing, or when a later sibling would cover it.
    public static func shouldRaise(isChildOfTarget: Bool, isFrontmost: Bool) -> Bool {
        !isChildOfTarget || !isFrontmost
    }
}

/// Collapses repeated layout-pass notifications into one delivery.
public struct LayoutNotifyCoalescer: Equatable {
    public private(set) var pending = false

    public init() {}

    /// True only for the first request until `take` runs.
    public mutating func request() -> Bool {
        if pending { return false }
        pending = true
        return true
    }

    /// Clears the pending flag. True when a request was waiting.
    @discardableResult
    public mutating func take() -> Bool {
        let was = pending
        pending = false
        return was
    }
}
