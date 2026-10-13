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

public enum AddressFormatting {
    public static func parts(for url: URL) -> AddressParts {
        if InternalPage.parse(url) != nil || url.scheme?.lowercased() == "wyvern" {
            let host = url.host ?? ""
            var tail = host
            if !url.path.isEmpty, url.path != "/" {
                tail += url.path
            }
            if let query = url.query, !query.isEmpty {
                tail += "?\(query)"
            }
            return AddressParts(primary: "wyvern://", secondary: tail)
        }
        if let host = url.host, !host.isEmpty {
            var head = host
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
            return AddressParts(primary: head, secondary: tail)
        }
        return AddressParts(primary: url.absoluteString, secondary: "")
    }

    public static func host(of raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }
        return trimmed
    }
}
