// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Graphite Depth colors (style A). Hex strings only; the AppKit target turns them into colors.
/// `tab` is the lower stop of an active web tab. Inactive web tabs are clear.
/// `accentFill` is the primary-button fill. In dark mode it is darker than `accent` so white text stays readable.
public struct ThemeTokens: Equatable, Sendable {
    public struct Palette: Equatable, Sendable {
        public var background: String
        public var bar1: String
        public var bar2: String
        public var tab: String
        public var tabA1: String
        public var text: String
        public var mute: String
        public var line: String
        public var accent: String
        public var accentFill: String
        public var field: String
        public var page: String
        public var card: String
        public var barLine: String
        public var barLineAlpha: Double
        public var highlight: String
        public var highlightAlpha: Double
        public var fieldLine: String
        public var fieldLineAlpha: Double
        public var termTab: String
        public var termTabActive: String
        public var termGlyph: String
        public var termBackground: String
        public var termText: String
        public var termPrompt: String
        public var termDim: String
        public var termOutline: String
        public var termOutlineAlpha: Double

        public init(
            background: String,
            bar1: String,
            bar2: String,
            tab: String,
            tabA1: String,
            text: String,
            mute: String,
            line: String,
            accent: String,
            accentFill: String,
            field: String,
            page: String,
            card: String,
            barLine: String,
            barLineAlpha: Double,
            highlight: String,
            highlightAlpha: Double,
            fieldLine: String,
            fieldLineAlpha: Double,
            termTab: String,
            termTabActive: String,
            termGlyph: String,
            termBackground: String,
            termText: String,
            termPrompt: String,
            termDim: String,
            termOutline: String,
            termOutlineAlpha: Double
        ) {
            self.background = background
            self.bar1 = bar1
            self.bar2 = bar2
            self.tab = tab
            self.tabA1 = tabA1
            self.text = text
            self.mute = mute
            self.line = line
            self.accent = accent
            self.accentFill = accentFill
            self.field = field
            self.page = page
            self.card = card
            self.barLine = barLine
            self.barLineAlpha = barLineAlpha
            self.highlight = highlight
            self.highlightAlpha = highlightAlpha
            self.fieldLine = fieldLine
            self.fieldLineAlpha = fieldLineAlpha
            self.termTab = termTab
            self.termTabActive = termTabActive
            self.termGlyph = termGlyph
            self.termBackground = termBackground
            self.termText = termText
            self.termPrompt = termPrompt
            self.termDim = termDim
            self.termOutline = termOutline
            self.termOutlineAlpha = termOutlineAlpha
        }
    }

    public static let light = Palette(
        background: "#F6F7F8",
        bar1: "#F3F4F6",
        bar2: "#E4E6E9",
        tab: "#F7F8F9",
        tabA1: "#FFFFFF",
        text: "#16181B",
        mute: "#666B73",
        line: "#E1E3E6",
        accent: "#2F5BEA",
        accentFill: "#2F5BEA",
        field: "#FFFFFF",
        page: "#FFFFFF",
        card: "#F4F5F7",
        barLine: "#000000",
        barLineAlpha: 0.10,
        highlight: "#FFFFFF",
        highlightAlpha: 0.90,
        fieldLine: "#000000",
        fieldLineAlpha: 0.12,
        termTab: "#E6EEE9",
        termTabActive: "#F2F7F4",
        termGlyph: "#17834A",
        termBackground: "#FBFCFB",
        termText: "#1B2620",
        termPrompt: "#17834A",
        termDim: "#6A7A70",
        termOutline: "#17834A",
        termOutlineAlpha: 0.30
    )

    public static let dark = Palette(
        background: "#121315",
        bar1: "#26282C",
        bar2: "#1C1E21",
        tab: "#2B2E32",
        tabA1: "#34373C",
        text: "#ECEDEF",
        mute: "#8F949B",
        line: "#2A2C30",
        accent: "#7C9CFF",
        accentFill: "#4C6FE0",
        field: "#141518",
        page: "#17181A",
        card: "#1E2023",
        barLine: "#FFFFFF",
        barLineAlpha: 0.06,
        highlight: "#FFFFFF",
        highlightAlpha: 0.07,
        fieldLine: "#FFFFFF",
        fieldLineAlpha: 0.08,
        termTab: "#16201B",
        termTabActive: "#1B2620",
        termGlyph: "#2FBF71",
        termBackground: "#0C110E",
        termText: "#D6E2DA",
        termPrompt: "#2FBF71",
        termDim: "#6F8577",
        termOutline: "#2FBF71",
        termOutlineAlpha: 0.28
    )

    /// `#RRGGBB` to 0...255 channels. Returns nil when the string is not six hex digits.
    public static func rgb(hex: String) -> (red: Int, green: Int, blue: Int)? {
        var digits = hex
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard digits.count == 6, let value = Int(digits, radix: 16) else {
            return nil
        }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }
}
