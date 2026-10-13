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
    /// - `app1://bookmarks` and `app1://newtab` are returned as typed. Any other `app1` address becomes a search.
    /// - javascript and data are not navigated; they become a search.
    /// - A host-like token (dotted name with no spaces, localhost with an optional port, or IPv4 with an optional port) is prefixed with `https://`.
    ///   Loopback (`localhost` and `127.0.0.0/8`) is prefixed with `http://`.
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
            if lower == "app1", let url = URL(string: trimmed), InternalPage.parse(url) != nil {
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

    /// Loopback is http so a typed local address reaches an ordinary local server.
    /// Every other host-like token stays https.
    static func assumedScheme(for value: String) -> String {
        if isLocalhost(value) || isLoopbackIPv4(value) {
            return "http"
        }
        return "https"
    }

    static func looksLikeHost(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.contains(where: { $0.isWhitespace }) { return false }
        if value.contains("://") { return false }
        if isLocalhost(value) || isIPv4(value) { return true }
        return value.contains(".")
    }

    static func isLocalhost(_ value: String) -> Bool {
        let head = hostHead(value).lowercased()
        if head == "localhost" { return true }
        let parts = head.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "localhost" else { return false }
        return isPort(String(parts[1]))
    }

    static func isLoopbackIPv4(_ value: String) -> Bool {
        guard isIPv4(value) else { return false }
        let head = hostHead(value)
        let ip = head.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? head
        return ip.split(separator: ".").first == "127"
    }

    static func isIPv4(_ value: String) -> Bool {
        let head = hostHead(value)
        let parts = head.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, !isPort(String(parts[1])) {
            return false
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard octet.count >= 1, octet.count <= 3, octet.allSatisfy(\.isNumber) else { return false }
            guard let number = Int(octet), (0...255).contains(number) else { return false }
        }
        return true
    }

    private static func hostHead(_ value: String) -> String {
        if let slash = value.firstIndex(of: "/") {
            return String(value[..<slash])
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
