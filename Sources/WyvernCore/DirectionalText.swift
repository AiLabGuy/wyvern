// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Removes characters that reorder or break a single-line label.
/// Letters stay, including non-ASCII letters, so a caller can punycode them.
public enum DirectionalText {
    /// Bidi embeddings, overrides, isolates, marks, and line separators.
    private static let directional: Set<UInt32> = [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
        0x200E, 0x200F, 0x061C, 0xFEFF,
        0x2028, 0x2029
    ]

    public static func strippingControls(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }
            if directional.contains(scalar.value) { continue }
            out.append(scalar)
        }
        return String(out)
    }
}
