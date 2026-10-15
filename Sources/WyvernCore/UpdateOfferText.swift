// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Lines for the update sheet. Release notes are feed text and are labeled as such.
/// Signature checks are unchanged; this only formats what the sheet already shows.
public enum UpdateOfferText {
    public static func details(
        installedVersion: String,
        installedBuild: String,
        commit: String?,
        host: String,
        keyID: String,
        origin: UpdateSource.Origin,
        notes: String?
    ) -> String {
        var lines = [
            "You have version \(installedVersion) (build \(installedBuild)).",
            "Commit: \(commit ?? "not listed; read from the signature after download")",
            "Source: \(host) · key ID \(keyID)"
        ]
        if origin == .custom {
            lines.append("Custom update source: \(host), key \(keyID)")
        }
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            lines.append("")
            lines.append("Notes from the update source (not verified)")
            lines.append(String(trimmed.prefix(400)))
        }
        return lines.joined(separator: "\n")
    }
}
