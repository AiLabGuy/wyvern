// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// WCAG 2 relative luminance and contrast ratio for sRGB hex tokens.
/// Channel conversion and the 0.2126 / 0.7152 / 0.0722 weights follow WCAG 2.1 §1.4.3.
public enum ColorContrast: Sendable {
    /// Minimum contrast for normal text (WCAG AA).
    public static let aaNormalText = 4.5
    /// Minimum contrast for large text and non-text UI indicators (WCAG AA).
    public static let aaLargeOrUI = 3.0

    /// Linearize one 0...255 sRGB channel.
    public static func linearChannel(_ value: Int) -> Double {
        let channel = Double(value) / 255.0
        if channel <= 0.04045 {
            return channel / 12.92
        }
        return pow((channel + 0.055) / 1.055, 2.4)
    }

    public static func relativeLuminance(red: Int, green: Int, blue: Int) -> Double {
        0.2126 * linearChannel(red) + 0.7152 * linearChannel(green) + 0.0722 * linearChannel(blue)
    }

    /// Relative luminance of `#RRGGBB`. Nil when the string is not six hex digits.
    public static func relativeLuminance(hex: String) -> Double? {
        guard let rgb = ThemeTokens.rgb(hex: hex) else { return nil }
        return relativeLuminance(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// `(L1 + 0.05) / (L2 + 0.05)` with L1 the lighter luminance. Nil when either hex is invalid.
    public static func contrastRatio(foreground: String, background: String) -> Double? {
        guard let first = relativeLuminance(hex: foreground),
              let second = relativeLuminance(hex: background) else {
            return nil
        }
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public static func meetsAA(foreground: String, background: String, largeOrUI: Bool = false) -> Bool {
        guard let contrast = contrastRatio(foreground: foreground, background: background) else {
            return false
        }
        return contrast >= (largeOrUI ? aaLargeOrUI : aaNormalText)
    }
}
