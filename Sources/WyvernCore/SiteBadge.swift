// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Letter-badge colors from the C Mono palette. The same host always maps to the same entry.
public enum SiteBadge {
    public static let palette = ["#5B7C99", "#7A8F5B", "#99705B", "#6B6B99", "#8A9099"]
    /// Bookmark lists use one muted badge, matching the bookmarks screen.
    public static let listHex = "#8A9099"
    /// The new-tab tab uses a plus on this gray.
    public static let newTabHex = "#8A8A8A"

    public static func colorHex(forHost host: String) -> String {
        let key = host.lowercased()
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        let index = Int(hash % UInt32(palette.count))
        return palette[index]
    }

    public static func letter(forTitle title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let character = trimmed.first else { return "?" }
        if character.isLetter || character.isNumber {
            return String(character).uppercased()
        }
        return "?"
    }
}
