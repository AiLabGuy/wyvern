// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One typeface for the address text in every state the person can see it in.
///
/// The address bar used the system font at 13 pt while a new tab (no page URL) was being typed in,
/// and the monospaced font at 12 pt for the committed URL. Return therefore swapped the font under
/// the text. Every state now resolves to the same spec, and the UI builds its `NSFont` from it.
public enum AddressTypography {
    public enum Design: String, Equatable, Sendable {
        case monospaced
        case system
    }

    public struct Spec: Equatable, Sendable {
        public let design: Design
        public let size: Double
        /// Matches `NSFont.Weight.regular.rawValue` (0) for the regular weight.
        public let weight: Double
    }

    /// Where the address text is drawn.
    public enum State: CaseIterable, Sendable {
        /// The committed URL after Return or a navigation.
        case committedURL
        /// The field editor while the person edits the current page URL.
        case editingURL
        /// The field editor on a new tab or an empty field.
        case editingEmpty
        /// The read-only DevTools source URL.
        case devToolsSource
    }

    /// URLs use ui-monospace per the design spec. 12 pt regular is the committed URL size.
    public static let text = Spec(design: .monospaced, size: 12, weight: 0)

    public static func spec(for state: State) -> Spec {
        switch state {
        case .committedURL, .editingURL, .editingEmpty, .devToolsSource:
            return text
        }
    }
}
