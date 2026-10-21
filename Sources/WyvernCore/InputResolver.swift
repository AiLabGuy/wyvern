// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Percent-encoding for the `{query}` placeholder.
/// Starts from `CharacterSet.urlQueryAllowed` and removes `&`, `+`, `=`, `?`, and `#`
/// so those characters cannot change the query structure of the search template.
public enum QueryEncoding {
    public static func percentEncode(_ query: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
    }
}

/// Turns address-bar text into a URL. Foundation only; no AppKit.
public struct InputResolver: Equatable, Sendable {
    public var engine: SearchEngine

    public init(engine: SearchEngine) {
        self.engine = engine
    }

    /// - http, https, file, and about are returned as typed.
    /// - `wyvern://bookmarks` and `wyvern://newtab` are returned as typed. Any other `wyvern` address becomes a search.
    /// - javascript and data are not navigated; they become a search.
    /// - A host-like token with no scheme gets one: a dotted name, `localhost`, an IPv4 address,
    ///   a bracketed IPv6 address (`[::1]`), or a single-label name with a port (`nas:5000`).
    ///   Each may carry a port, path, query, or fragment.
    ///   - `http://` for IP literals, `localhost`, and any host with an explicit port other than 443.
    ///     Those are LAN devices and dev servers that rarely have a certificate for that name, so
    ///     `https://` would fail the TLS handshake and the bar would appear to do nothing.
    ///   - `https://` for a dotted name with no port (or port 443).
    ///   A single label with no port (`nas`) stays a search.
    /// - Anything else is a search on `engine`, falling back to DuckDuckGo if that template cannot build an https URL.
    public func resolve(_ rawInput: String) -> URL? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let scheme = Self.schemeName(in: trimmed) {
            let lower = scheme.lowercased()
            if lower == "http" || lower == "https" || lower == "file" || lower == "about" {
                if let url = URL(string: trimmed), url.scheme?.lowercased() == lower {
                    return url
                }
            }
            if lower == "wyvern", let url = URL(string: trimmed), InternalPage.parse(url) != nil {
                return url
            }
            // javascript:, data:, and any other scheme typed in the bar become a search.
            return searchURL(for: trimmed)
        }

        if Self.looksLikeHost(trimmed), let url = URL(string: "\(Self.assumedScheme(for: trimmed))://\(trimmed)") {
            return url
        }
        return searchURL(for: trimmed)
    }

    private func searchURL(for query: String) -> URL? {
        if let url = engine.url(forQuery: query) {
            return url
        }
        return SearchEngine.duckDuckGo.url(forQuery: query)
    }

    /// Scheme token when the text contains `://`, or a known scheme before a bare colon.
    /// A bare colon is not enough: `localhost:8080` is a host, not a scheme.
    static func schemeName(in value: String) -> String? {
        let end: String.Index
        let hasSlashes: Bool
        if let range = value.range(of: "://") {
            end = range.lowerBound
            hasSlashes = true
        } else if let colon = value.firstIndex(of: ":") {
            end = colon
            hasSlashes = false
        } else {
            return nil
        }

        let raw = value[..<end]
        guard let first = raw.unicodeScalars.first, CharacterSet.letters.contains(first) else {
            return nil
        }
        let valid = raw.unicodeScalars.allSatisfy { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "+"
                || scalar == "-"
                || scalar == "."
        }
        guard valid, !raw.isEmpty else { return nil }

        if !hasSlashes {
            let known: Set<String> = [
                "http", "https", "file", "about", "javascript", "data",
                "blob", "mailto", "ftp", "ws", "wss"
            ]
            guard known.contains(raw.lowercased()) else { return nil }
        }
        return String(raw)
    }

    /// IP literals, localhost, and explicit ports (other than 443) are http; see `resolve`.
    /// Every other host-like token stays https.
    static func assumedScheme(for value: String) -> String {
        let port = hostAndPort(hostHead(value))?.port.flatMap { Int($0) }
        if port == 443 {
            return "https"
        }
        if isLocalhost(value) || isIPv4(value) || isBracketedIPv6(value) || port != nil {
            return "http"
        }
        return "https"
    }

    static func looksLikeHost(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.contains(where: { $0.isWhitespace }) { return false }
        if value.contains("://") { return false }
        if isLocalhost(value) || isIPv4(value) || isBracketedIPv6(value) || isSingleLabelWithPort(value) { return true }
        return value.contains(".")
    }

    static func isLocalhost(_ value: String) -> Bool {
        guard let parts = hostAndPort(hostHead(value)) else { return false }
        return parts.host.lowercased() == "localhost"
    }

    static func isIPv4(_ value: String) -> Bool {
        guard let parts = hostAndPort(hostHead(value)), !parts.host.hasPrefix("[") else { return false }
        let octets = parts.host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard octet.count >= 1, octet.count <= 3, octet.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            guard let number = Int(octet), (0...255).contains(number) else { return false }
        }
        return true
    }

    /// `[::1]`, `[fe80::1]:8080`, `[2001:db8::5]/path`. Brackets are required, as in a URL.
    static func isBracketedIPv6(_ value: String) -> Bool {
        guard let parts = hostAndPort(hostHead(value)), parts.host.hasPrefix("["), parts.host.hasSuffix("]") else {
            return false
        }
        let inner = parts.host.dropFirst().dropLast()
        guard inner.count >= 2, inner.contains(":") else { return false }
        let allowed = Set("0123456789abcdefABCDEF:.")
        guard inner.allSatisfy({ allowed.contains($0) }) else { return false }
        // At most one `::`, and no more than eight groups.
        if inner.components(separatedBy: "::").count > 2 { return false }
        return inner.split(separator: ":", omittingEmptySubsequences: true).count <= 8
    }

    /// `nas:5000`, `printer:631/admin`: one DNS label and a valid port.
    static func isSingleLabelWithPort(_ value: String) -> Bool {
        guard let parts = hostAndPort(hostHead(value)), parts.port != nil else { return false }
        let label = parts.host
        guard !label.isEmpty, label.count <= 63, !label.contains("."), !label.hasPrefix("-"), !label.hasSuffix("-") else {
            return false
        }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Splits `host[:port]` or `[v6][:port]`. Nil when a port is present but not 1...65535.
    static func hostAndPort(_ head: String) -> (host: String, port: String?)? {
        if head.hasPrefix("[") {
            guard let close = head.firstIndex(of: "]") else { return nil }
            let host = String(head[...close])
            let rest = head[head.index(after: close)...]
            if rest.isEmpty { return (host, nil) }
            guard rest.first == ":" else { return nil }
            let port = String(rest.dropFirst())
            return isPort(port) ? (host, port) : nil
        }
        let parts = head.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let port = String(parts[1])
            return isPort(port) ? (String(parts[0]), port) : nil
        }
        return (head, nil)
    }

    /// The authority part: everything before the first `/`, `?`, or `#`.
    private static func hostHead(_ value: String) -> String {
        if let end = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            return String(value[..<end])
        }
        return value
    }

    private static func isPort(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 5, value.allSatisfy(\.isNumber), let number = Int(value) else {
            return false
        }
        return (1...65535).contains(number)
    }
}
