// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// WebKit XPC helpers the memory sampler attributes to the app.
///
/// `proc_name` truncates to `MAXCOMLEN` (16), so `com.apple.WebKit.WebContent`
/// becomes `com.apple.WebKit` with no trailing dot. Callers should pass
/// `proc_pidpath` as well as the short name.
public enum WebKitHelperKind: String, Equatable, Sendable {
    case webContent
    case networking
    case gpu

    /// Map a process name or path onto WebContent, Networking, or GPU.
    /// Checked in that order. Returns nil when none of the three appear.
    public static func classify(nameOrPath: String) -> WebKitHelperKind? {
        let lower = nameOrPath.lowercased()
        if lower.contains("webcontent") { return .webContent }
        if lower.contains("networking") { return .networking }
        if lower.contains("gpu") { return .gpu }
        return nil
    }

    /// True when `proc_name` or `proc_pidpath` names a WebKit XPC service.
    public static func isWebKitHelper(name: String, path: String) -> Bool {
        if name.contains("com.apple.WebKit") { return true }
        if path.contains("com.apple.WebKit.") { return true }
        return false
    }
}
