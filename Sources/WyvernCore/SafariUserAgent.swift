// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// The `applicationNameForUserAgent` every page web view uses.
///
/// WebKit builds the user agent as `Mozilla/5.0 (...) AppleWebKit/605.1.15 (KHTML, like Gecko)`
/// followed by the application name. Safari's application name is `Version/<x.y> Safari/605.1.15`.
/// A bare WKWebView has no application name, so its user agent stops after `(KHTML, like Gecko)`.
/// Some sites treat that as an unknown, old browser: Google serves its legacy basic homepage
/// (I'm Feeling Lucky buttons, no AI Mode) to it.
///
/// The value is exactly what Safari on this Mac sends, so the browser blends in with Safari
/// instead of standing out. There is no app-specific token: a page cannot tell Wyvern from Safari
/// by its user agent, and nothing new identifies the person. `customUserAgent` stays unset, so
/// WebKit still writes the platform, OS, and engine parts itself.
public enum SafariUserAgent {
    /// WebKit has frozen this token since 2017; Safari still sends it.
    public static let safariBuildToken = "605.1.15"
    /// Safari's `Info.plist` on macOS 13 and later. The app is a firmlink into the Safari cryptex.
    public static let safariInfoPlistPaths = [
        "/Applications/Safari.app/Contents/Info.plist",
        "/System/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist"
    ]

    /// `Version/<version> Safari/605.1.15`. A missing or malformed version uses `fallbackVersion`.
    public static func applicationName(safariVersion: String?, osMajor: Int) -> String {
        let version = sanitized(safariVersion) ?? fallbackVersion(osMajor: osMajor)
        return "Version/\(version) Safari/\(safariBuildToken)"
    }

    /// Digits and dots only, one to three parts, for example `27.0.1`. Anything else is nil,
    /// so a damaged plist cannot put arbitrary text into every request.
    public static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), value.count <= 16 else { return nil }
        for part in parts {
            guard !part.isEmpty, part.count <= 4, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        }
        return value
    }

    /// The Safari that ships with each macOS: 13 → 16, 14 → 17, 15 → 18, and from 26 the
    /// numbers match. Used only when Safari's own version cannot be read.
    public static func fallbackVersion(osMajor: Int) -> String {
        switch osMajor {
        case ..<14: return "16.0"
        case 14: return "17.0"
        case 15: return "18.0"
        default: return "\(max(osMajor, 26)).0"
        }
    }

    /// `CFBundleShortVersionString` from the first readable Safari `Info.plist`.
    public static func installedSafariVersion(paths: [String] = safariInfoPlistPaths) -> String? {
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = sanitized(plist["CFBundleShortVersionString"] as? String) else {
                continue
            }
            return version
        }
        return nil
    }

    /// Read once per launch. A Safari update takes effect the next time Wyvern starts.
    public static let current: String = applicationName(
        safariVersion: installedSafariVersion(),
        osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )

    #if canImport(WebKit)
    /// Sets the application name. Must run before the web view is created from `configuration`.
    @MainActor
    public static func apply(to configuration: WKWebViewConfiguration, applicationName: String = current) {
        configuration.applicationNameForUserAgent = applicationName
    }
    #endif
}
