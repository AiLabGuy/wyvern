// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Which command-clicked terminal links may be opened.
/// The terminal can print any string as a link. Only http and https are handed to the opener.
public enum TerminalLinkPolicy {
    public static func allows(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_048 else { return false }
        guard let components = URLComponents(string: trimmed) else { return false }
        guard components.user == nil, components.password == nil else { return false }
        guard let scheme = components.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = components.host, host.isEmpty == false else { return false }
        return true
    }
}
