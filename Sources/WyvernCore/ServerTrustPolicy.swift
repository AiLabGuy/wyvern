// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Security

/// How a server-trust challenge is answered. Never accepts every certificate.
public enum ServerTrustDisposition: Equatable, Sendable {
    /// The system decides. Used for non-server-trust, for certs that evaluate as trusted,
    /// and for untrusted loads that are not the main frame (no prompt, no credential).
    case performDefaultHandling
    /// Explicit Continue, or a session allowlist hit. Default handling would fail the load.
    case useCredential
    /// Untrusted main-frame load. The app shows the native warning.
    case prompt
}

/// Hostname policy and main-frame classification for `WKNavigationDelegate` server trust.
///
/// `SecTrustEvaluateWithError` without an SSL policy for the protection-space host matches
/// the certificate CN and can ignore a SAN (`*.ytimg.com` on a `*.google.com` CN). The
/// policy has to be applied before that call. Live trust evaluation is not unit-tested.
public enum ServerTrustPolicy {
    public static func normalizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]"), host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }

    /// Server-trust challenges need `SecPolicyCreateSSL` for the protection-space host.
    /// Other authentication methods keep default handling.
    public static func needsHostSSLPolicy(authenticationMethod: String) -> Bool {
        authenticationMethod == NSURLAuthenticationMethodServerTrust
    }

    /// An empty host cannot be pinned to a name, so no SSL hostname policy is applied.
    public static func canApplyHostSSLPolicy(host: String) -> Bool {
        !normalizedHost(host).isEmpty
    }

    /// True when this challenge must be evaluated with an SSL policy for `host`.
    public static func requiresHostSSLPolicy(authenticationMethod: String, host: String) -> Bool {
        needsHostSSLPolicy(authenticationMethod: authenticationMethod) && canApplyHostSSLPolicy(host: host)
    }

    /// The challenge API has no frame. The protection-space host is the main frame only when
    /// it equals the provisional or committed page host. `i.ytimg.com` on `youtube.com` is not.
    /// A missing page host (the navigation has not published one yet) stays a main-frame
    /// challenge so a typed untrusted host can still show the warning.
    public static func isMainFrameChallenge(protectionSpaceHost: String, mainFrameHost: String?) -> Bool {
        let challenge = normalizedHost(protectionSpaceHost)
        guard !challenge.isEmpty else { return false }
        guard let mainFrameHost else { return true }
        let page = normalizedHost(mainFrameHost)
        guard !page.isEmpty else { return true }
        return challenge == page
    }

    public static func disposition(
        isServerTrust: Bool,
        evaluatedTrusted: Bool,
        sessionAllowlisted: Bool,
        isMainFrame: Bool
    ) -> ServerTrustDisposition {
        guard isServerTrust else { return .performDefaultHandling }
        if evaluatedTrusted { return .performDefaultHandling }
        if sessionAllowlisted { return .useCredential }
        if isMainFrame { return .prompt }
        return .performDefaultHandling
    }

    /// Installs an SSL server policy so evaluation checks the SAN against `host`.
    /// Returns false when `host` is empty; the trust object is left unchanged.
    @discardableResult
    public static func applySSLPolicy(to trust: SecTrust, host: String) -> Bool {
        let name = normalizedHost(host)
        guard !name.isEmpty else { return false }
        let policy = SecPolicyCreateSSL(true, name as CFString)
        // Hostname only. The port stays on the allowlist key; the certificate names the host.
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess else { return false }
        return true
    }

    /// Applies the host SSL policy, then evaluates. A chain that is valid for a different
    /// name returns false. Does not accept certificates that fail evaluation.
    public static func isSystemTrusted(_ trust: SecTrust, host: String) -> Bool {
        guard applySSLPolicy(to: trust, host: host) else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}
