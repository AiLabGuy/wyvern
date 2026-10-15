// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Capture kind stored with an origin. `both` is camera and microphone together.
public enum MediaCaptureKind: String, Codable, Equatable, CaseIterable, Sendable {
    case microphone
    case camera
    case both
}

/// Lasting choice for one origin and kind. Absent means ask next time.
public enum MediaStoredDecision: String, Codable, Equatable, Sendable {
    case alwaysAllow
    case alwaysDeny
}

/// Buttons on the in-app prompt. Don't Allow does not persist.
public enum MediaPromptChoice: Equatable, Sendable {
    case allowOnce
    case alwaysAllow
    case deny
}

/// Immediate answer without showing the in-app prompt.
public enum MediaImmediateDecision: Equatable, Sendable {
    case grant
    case deny
    case prompt
}

/// Origin key is `scheme://host` or `scheme://host:port` from `WKSecurityOrigin`.
/// Only `https` and `http://localhost` / `http://127.0.0.1` may be allowed. Other
/// origins are denied without a prompt.
public enum MediaPermissionPolicy {
    public static func originKey(scheme: String, host: String, port: Int) -> String {
        let scheme = scheme.lowercased()
        let host = host.lowercased()
        let omitPort = port == 0
            || (scheme == "http" && port == 80)
            || (scheme == "https" && port == 443)
        if omitPort {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    /// Text the permission sheet names. It is the top-level origin of the tab that
    /// asked, so a frame cannot be the only name on the sheet. A different requesting
    /// frame is written after that origin. The string is complete; the label truncates
    /// the tail and keeps this value in the tooltip.
    public static func sheetOrigin(topLevelURL: URL?, requesterOrigin: String) -> String {
        let requester = requesterOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let topLevelURL,
              let top = SitePermissionPolicy.originKey(for: topLevelURL),
              !top.isEmpty else {
            return requester
        }
        if requester.isEmpty || requester.lowercased() == top.lowercased() {
            return top
        }
        return "\(top) (requesting frame \(requester))"
    }

    /// A cross-origin iframe cannot raise the camera or microphone prompt.
    /// Same-origin frames still can. The main frame is decided on its own origin.
    public static func allowsFrame(isMainFrame: Bool, requesterOrigin: String, topLevelURL: URL?) -> Bool {
        if isMainFrame {
            return true
        }
        guard let topLevelURL, let top = SitePermissionPolicy.originKey(for: topLevelURL) else {
            return false
        }
        return requesterOrigin.lowercased() == top.lowercased()
    }

    public static func isEligibleOrigin(_ key: String) -> Bool {
        guard let components = URLComponents(string: key),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        if scheme == "https" {
            return true
        }
        if scheme == "http" {
            return host == "localhost" || host == "127.0.0.1"
        }
        return false
    }

    public static func evaluate(
        originKey: String,
        kind: MediaCaptureKind,
        stored: MediaStoredDecision?
    ) -> MediaImmediateDecision {
        _ = kind
        guard isEligibleOrigin(originKey) else { return .deny }
        switch stored {
        case .alwaysAllow:
            return .grant
        case .alwaysDeny:
            return .deny
        case nil:
            return .prompt
        }
    }

    /// Camera and microphone requests read only that device.
    /// A combined request keeps a stored `both` choice unchanged.
    /// When `both` is absent, a nil camera or microphone value is Ask and stays a prompt.
    /// Allow or Block is synthesized only when both devices have an explicit choice.
    public static func effectiveStoredDecision(
        requested kind: MediaCaptureKind,
        camera: MediaStoredDecision?,
        microphone: MediaStoredDecision?,
        both: MediaStoredDecision?
    ) -> MediaStoredDecision? {
        switch kind {
        case .camera:
            return camera
        case .microphone:
            return microphone
        case .both:
            if let both {
                return both
            }
            guard let camera, let microphone else { return nil }
            if camera == .alwaysDeny || microphone == .alwaysDeny {
                return .alwaysDeny
            }
            return .alwaysAllow
        }
    }

    /// Maps a prompt button to grant/deny and an optional stored decision.
    public static func apply(_ choice: MediaPromptChoice) -> (grant: Bool, stored: MediaStoredDecision?) {
        switch choice {
        case .allowOnce:
            return (true, nil)
        case .alwaysAllow:
            return (true, .alwaysAllow)
        case .deny:
            return (false, nil)
        }
    }
}
