// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One open tab the palette can match. `url` is the page address, or the terminal command.
public struct TabSearchEntry: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: String
    public var kind: TabKind

    public init(id: UUID, title: String, url: String, kind: TabKind) {
        self.id = id
        self.title = title
        self.url = url
        self.kind = kind
    }
}

public enum TabSearch {
    /// Case-insensitive substring on title and URL. A blank query returns every entry, in order.
    public static func filter(_ entries: [TabSearchEntry], query: String) -> [TabSearchEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            return entries
        }
        return entries.filter { entry in
            contains(entry.title, needle) || contains(entry.url, needle)
        }
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: .caseInsensitive) != nil
    }
}
