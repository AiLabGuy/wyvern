// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A search endpoint. Built-in templates contain only a `q` parameter.
/// A custom template must be `https` and must contain the literal `{query}`.
public struct SearchEngine: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var template: String

    public init(id: String, name: String, template: String) {
        self.id = id
        self.name = name
        self.template = template
    }

    public static let customID = "custom"

    public static let duckDuckGo = SearchEngine(
        id: "duckduckgo",
        name: "DuckDuckGo",
        template: "https://duckduckgo.com/?q={query}"
    )

    public static let google = SearchEngine(
        id: "google",
        name: "Google",
        template: "https://www.google.com/search?q={query}"
    )

    public static let bing = SearchEngine(
        id: "bing",
        name: "Bing",
        template: "https://www.bing.com/search?q={query}"
    )

    public static let kagi = SearchEngine(
        id: "kagi",
        name: "Kagi",
        template: "https://kagi.com/search?q={query}"
    )

    public static let startpage = SearchEngine(
        id: "startpage",
        name: "Startpage",
        template: "https://www.startpage.com/do/search?q={query}"
    )

    public static let builtIns: [SearchEngine] = [
        duckDuckGo,
        google,
        bing,
        kagi,
        startpage
    ]

    /// Returns a custom engine, or nil when the template is not https or lacks `{query}`.
    public static func custom(template: String) -> SearchEngine? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("{query}") else { return nil }
        guard trimmed.lowercased().hasPrefix("https://") else { return nil }
        let sample = trimmed.replacingOccurrences(of: "{query}", with: "test")
        guard let url = URL(string: sample),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return SearchEngine(id: customID, name: "Custom", template: trimmed)
    }

    public static func builtIn(id: String) -> SearchEngine? {
        builtIns.first { $0.id == id }
    }

    /// Builds an https URL by replacing `{query}` with the encoded query.
    public func url(forQuery query: String) -> URL? {
        guard template.contains("{query}") else { return nil }
        let encoded = QueryEncoding.percentEncode(query)
        let concrete = template.replacingOccurrences(of: "{query}", with: encoded)
        guard let url = URL(string: concrete), url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }
}
