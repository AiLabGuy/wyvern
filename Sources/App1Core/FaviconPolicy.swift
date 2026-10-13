// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Chooses a favicon URL that stays on the page host.
/// An absolute icon is accepted only when its host equals the page host.
/// A relative icon is resolved against the page and kept only when that stays on the page host.
/// An `http` icon on an `https` page is rejected.
/// Anything else falls back to `https://<page host>/favicon.ico`.
public enum FaviconPolicy {
    public static func iconURL(pageURL: URL, linkHref: String?) -> URL? {
        guard let host = pageURL.host?.lowercased(), !host.isEmpty else { return nil }
        guard let pageScheme = pageURL.scheme?.lowercased(),
              pageScheme == "http" || pageScheme == "https" else {
            return nil
        }

        let href = (linkHref ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if href.isEmpty {
            return fallback(host: host)
        }
        if let resolved = resolve(pageURL: pageURL, href: href),
           isSameOriginIcon(resolved, pageHost: host, pageScheme: pageScheme) {
            return resolved
        }
        return fallback(host: host)
    }

    public static func fallback(host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }

    private static func resolve(pageURL: URL, href: String) -> URL? {
        if let absolute = URL(string: href, relativeTo: pageURL)?.absoluteURL {
            return absolute
        }
        return URL(string: href)
    }

    private static func isSameOriginIcon(_ url: URL, pageHost: String, pageScheme: String) -> Bool {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        // An https page must not pull an icon over http.
        if pageScheme == "https", scheme == "http" {
            return false
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return host == pageHost
    }
}
