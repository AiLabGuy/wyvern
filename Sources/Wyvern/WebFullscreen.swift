// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore
import WebKit

extension NSView {
    /// True while this view is a web view that WebKit has moved into, or is moving into or out
    /// of, its element fullscreen window. Hosts must not re-parent it then.
    @MainActor
    var isInElementFullscreen: Bool {
        guard let webView = self as? WKWebView else { return false }
        return webView.fullscreenState != .notInFullscreen
    }

    /// How many of this view's four edges are pinned to `host` by active constraints.
    @MainActor
    func pinnedEdgeCount(in host: NSView) -> Int {
        var edges = Set<NSLayoutConstraint.Attribute>()
        for constraint in host.constraints where constraint.isActive {
            let first = constraint.firstItem as AnyObject?
            let second = constraint.secondItem as AnyObject?
            if first === self, second === host {
                edges.insert(constraint.firstAttribute)
            } else if second === self, first === host {
                edges.insert(constraint.secondAttribute)
            }
        }
        return edges.intersection([.leading, .trailing, .top, .bottom, .left, .right]).count
    }
}
