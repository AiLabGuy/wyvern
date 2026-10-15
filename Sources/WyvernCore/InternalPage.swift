// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Pages drawn by AppKit instead of the web view.
public enum InternalPage: Equatable, Sendable {
    case bookmarks
    case newTab

    public var url: URL {
        switch self {
        case .bookmarks:
            return URL(string: "wyvern://bookmarks") ?? URL(fileURLWithPath: "/")
        case .newTab:
            return URL(string: "wyvern://newtab") ?? URL(fileURLWithPath: "/")
        }
    }

    public static func parse(_ url: URL) -> InternalPage? {
        guard url.scheme?.lowercased() == "wyvern" else { return nil }
        switch url.host?.lowercased() {
        case "bookmarks":
            return .bookmarks
        case "newtab":
            return .newTab
        default:
            return nil
        }
    }
}

/// Splits an address the way the mono field does: an emphasized head and a muted tail.
public struct AddressParts: Equatable, Sendable {
    public var primary: String
    public var secondary: String

    public init(primary: String, secondary: String) {
        self.primary = primary
        self.secondary = secondary
    }
}

/// Which URL the address field may show while a navigation is in flight.
/// A provisional URL stays off the field until the document commits, except
/// the address the person just typed.
public enum AddressCommit {
    public enum Choice: Equatable, Sendable {
        case keepDisplayed
        case keepCommitted
        case adoptCandidate
    }

    public static func choice(showingTypedTarget: Bool, loading: Bool) -> Choice {
        if showingTypedTarget {
            return .keepDisplayed
        }
        if loading {
            return .keepCommitted
        }
        return .adoptCandidate
    }
}

/// The toolbar lock is a security indicator. Only an https URL may show it.
public enum AddressSecurity {
    public static func showsLock(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https"
    }
}

public enum AddressFormatting {
    /// Hosts longer than this are shown from the registrable end, so a padded
    /// subdomain cannot push the real site out of a truncated field.
    static let hostLengthLimit = 64

    public static func parts(for url: URL) -> AddressParts {
        if InternalPage.parse(url) != nil || url.scheme?.lowercased() == "wyvern" {
            let host = safeHost(url.host ?? "")
            var tail = host
            if !url.path.isEmpty, url.path != "/" {
                tail += url.path
            }
            if let query = url.query, !query.isEmpty {
                tail += "?\(query)"
            }
            return AddressParts(primary: "wyvern://", secondary: DirectionalText.strippingControls(tail))
        }
        if let host = url.host, !host.isEmpty {
            // `userinfo@` is not part of `host`. A non-ASCII host is punycode
            // so a lookalike letter cannot impersonate another site.
            var head = safeHost(host)
            if let port = url.port {
                head += ":\(port)"
            }
            var tail = ""
            if !url.path.isEmpty, url.path != "/" {
                tail += url.path
            }
            if let query = url.query, !query.isEmpty {
                tail += "?\(query)"
            }
            return AddressParts(primary: head, secondary: DirectionalText.strippingControls(tail))
        }
        return AddressParts(primary: cappedFallback(url.absoluteString), secondary: "")
    }

    /// ASCII host safe to put in the address field. Non-ASCII labels become punycode.
    /// A very long name keeps its last two labels.
    public static func safeHost(_ host: String) -> String {
        var cleaned = DirectionalText.strippingControls(host)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix(".") {
            cleaned.removeLast()
        }
        let labels = cleaned.split(separator: ".", omittingEmptySubsequences: false).map { label in
            asciiLabel(String(label))
        }
        let ascii = labels.joined(separator: ".")
        return elideLongHost(ascii)
    }

    private static func asciiLabel(_ label: String) -> String {
        if label.unicodeScalars.allSatisfy(\.isASCII) {
            return label
        }
        let points = label.unicodeScalars.map(\.value)
        if let encoded = Punycode.encode(points), !encoded.isEmpty {
            return "xn--" + encoded
        }
        let ascii = String(label.unicodeScalars.filter(\.isASCII).map { Character($0) })
        return ascii.isEmpty ? "xn--" : ascii
    }

    private static func elideLongHost(_ host: String) -> String {
        guard host.count > hostLengthLimit else { return host }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return host }
        let tailCount = min(2, labels.count)
        var tail = labels.suffix(tailCount).joined(separator: ".")
        if tail.count > hostLengthLimit {
            tail = String(tail.suffix(hostLengthLimit))
        }
        return "…" + tail
    }

    /// Schemeless fallback (file and blob). Keep the end, which holds the file name.
    private static func cappedFallback(_ text: String) -> String {
        let cleaned = DirectionalText.strippingControls(text)
        let limit = 120
        guard cleaned.count > limit else { return cleaned }
        return "…" + String(cleaned.suffix(limit - 1))
    }

    public static func host(of raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }
        return trimmed
    }
}
