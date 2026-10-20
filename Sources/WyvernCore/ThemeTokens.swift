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

    /// Classic Hermès navy chrome with gold selection, focus, and active-tab indicators.
    public static let hermes = Palette(
        background: "#0B2A6F",
        bar1: "#123C8C",
        bar2: "#0E3278",
        tab: "#154498",
        tabA1: "#1850B0",
        text: "#F4F6FB",
        mute: "#C9D2E6",
        line: "#1E4A96",
        accent: "#F2C230",
        accentFill: "#7A5C0A",
        field: "#07163F",
        page: "#081A48",
        card: "#0E3278",
        barLine: "#FFFFFF",
        barLineAlpha: 0.10,
        highlight: "#FFFFFF",
        highlightAlpha: 0.08,
        fieldLine: "#FFFFFF",
        fieldLineAlpha: 0.12,
        termTab: "#0C2460",
        termTabActive: "#123070",
        termGlyph: "#F2C230",
        termBackground: "#081538",
        termText: "#E8EEF8",
        termPrompt: "#E8B923",
        termDim: "#A8B4D0",
        termOutline: "#F2C230",
        termOutlineAlpha: 0.32
    )

    /// Neutral midnight graphite. Distinct from the default Dark pair.
    public static let graphite = Palette(
        background: "#0D0F12",
        bar1: "#1A1D22",
        bar2: "#14171C",
        tab: "#22262C",
        tabA1: "#2A2F36",
        text: "#E8EAED",
        mute: "#A8B0BA",
        line: "#2C3138",
        accent: "#8FA4B8",
        accentFill: "#3E5163",
        field: "#0A0C0F",
        page: "#101318",
        card: "#181B20",
        barLine: "#FFFFFF",
        barLineAlpha: 0.08,
        highlight: "#FFFFFF",
        highlightAlpha: 0.07,
        fieldLine: "#FFFFFF",
        fieldLineAlpha: 0.10,
        termTab: "#141A16",
        termTabActive: "#1A221C",
        termGlyph: "#3DCF7A",
        termBackground: "#0A0D0B",
        termText: "#D5E0D8",
        termPrompt: "#3DCF7A",
        termDim: "#8A9A90",
        termOutline: "#3DCF7A",
        termOutlineAlpha: 0.28
    )

    /// Warm paper / sepia light chrome.
    public static let paper = Palette(
        background: "#F6F0E4",
        bar1: "#F3EAD8",
        bar2: "#E8DCC6",
        tab: "#FBF6EC",
        tabA1: "#FFFBF3",
        text: "#3B2F24",
        mute: "#6B5B4A",
        line: "#E0D2BC",
        accent: "#8B4E24",
        accentFill: "#8B4E24",
        field: "#FFFBF4",
        page: "#FFF9F0",
        card: "#F3E9D8",
        barLine: "#000000",
        barLineAlpha: 0.10,
        highlight: "#FFFFFF",
        highlightAlpha: 0.70,
        fieldLine: "#000000",
        fieldLineAlpha: 0.12,
        termTab: "#EDE4D4",
        termTabActive: "#F5EDE0",
        termGlyph: "#2F6B45",
        termBackground: "#FBF7F0",
        termText: "#2A241C",
        termPrompt: "#2F6B45",
        termDim: "#6E6458",
        termOutline: "#2F6B45",
        termOutlineAlpha: 0.30
    )

    /// Cool Nord polar-night chrome with frost accents.
    public static let nord = Palette(
        background: "#2E3440",
        bar1: "#3B4252",
        bar2: "#2E3440",
        tab: "#434C5E",
        tabA1: "#4C566A",
        text: "#ECEFF4",
        mute: "#D8DEE9",
        line: "#434C5E",
        accent: "#88C0D0",
        accentFill: "#4C6A91",
        field: "#242933",
        page: "#242933",
        card: "#3B4252",
        barLine: "#FFFFFF",
        barLineAlpha: 0.08,
        highlight: "#FFFFFF",
        highlightAlpha: 0.08,
        fieldLine: "#FFFFFF",
        fieldLineAlpha: 0.10,
        termTab: "#2A303C",
        termTabActive: "#323845",
        termGlyph: "#A3BE8C",
        termBackground: "#1D2128",
        termText: "#D8DEE9",
        termPrompt: "#A3BE8C",
        termDim: "#9AA6B8",
        termOutline: "#A3BE8C",
        termOutlineAlpha: 0.28
    )

    /// String hex fields on `Palette`. Tests compare this set to mirrored stored properties.
    public static let hexTokenNames: Set<String> = [
        "background", "bar1", "bar2", "tab", "tabA1", "text", "mute", "line",
        "accent", "accentFill", "field", "page", "card", "barLine", "highlight",
        "fieldLine", "termTab", "termTabActive", "termGlyph", "termBackground",
        "termText", "termPrompt", "termDim", "termOutline"
    ]

    public static let alphaTokenNames: Set<String> = [
        "barLineAlpha", "highlightAlpha", "fieldLineAlpha", "termOutlineAlpha"
    ]

    /// Palettes shown as unique chrome (Match System reuses Light and Dark).
    public static let catalog: [(id: String, name: String, palette: Palette)] = [
        ("light", ThemeChoice.light.displayName, light),
        ("dark", ThemeChoice.dark.displayName, dark),
        ("hermes", ThemeChoice.hermes.displayName, hermes),
        ("graphite", ThemeChoice.graphite.displayName, graphite),
        ("paper", ThemeChoice.paper.displayName, paper),
        ("nord", ThemeChoice.nord.displayName, nord)
    ]

    public static func palette(for theme: ColorTheme, darkAppearance: Bool) -> Palette {
        switch theme {
        case .standard:
            return darkAppearance ? dark : light
        case .hermes:
            return hermes
        case .graphite:
            return graphite
        case .paper:
            return paper
        case .nord:
            return nord
        }
    }

    public static func palette(for choice: ThemeChoice, darkAppearance: Bool) -> Palette {
        palette(for: choice.colorTheme, darkAppearance: darkAppearance)
    }

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

extension ThemeTokens.Palette {
    /// Every stored hex field. Used by tests so a new token cannot ship empty.
    public var hexTokens: [(name: String, value: String)] {
        [
            ("background", background),
            ("bar1", bar1),
            ("bar2", bar2),
            ("tab", tab),
            ("tabA1", tabA1),
            ("text", text),
            ("mute", mute),
            ("line", line),
            ("accent", accent),
            ("accentFill", accentFill),
            ("field", field),
            ("page", page),
            ("card", card),
            ("barLine", barLine),
            ("highlight", highlight),
            ("fieldLine", fieldLine),
            ("termTab", termTab),
            ("termTabActive", termTabActive),
            ("termGlyph", termGlyph),
            ("termBackground", termBackground),
            ("termText", termText),
            ("termPrompt", termPrompt),
            ("termDim", termDim),
            ("termOutline", termOutline)
        ]
    }

    public var alphaTokens: [(name: String, value: Double)] {
        [
            ("barLineAlpha", barLineAlpha),
            ("highlightAlpha", highlightAlpha),
            ("fieldLineAlpha", fieldLineAlpha),
            ("termOutlineAlpha", termOutlineAlpha)
        ]
    }

    /// Stored `String` properties via Mirror, for completeness against `hexTokenNames`.
    public var mirroredHexTokens: [String: String] {
        var tokens: [String: String] = [:]
        for child in Mirror(reflecting: self).children {
            guard let name = child.label, let value = child.value as? String else { continue }
            tokens[name] = value
        }
        return tokens
    }

    public var mirroredAlphaTokens: [String: Double] {
        var tokens: [String: Double] = [:]
        for child in Mirror(reflecting: self).children {
            guard let name = child.label, let value = child.value as? Double else { continue }
            tokens[name] = value
        }
        return tokens
    }
}

/// Named chrome palettes. `standard` is the existing Light/Dark pair and follows appearance.
public enum ColorTheme: String, Codable, CaseIterable, Sendable {
    case standard
    case hermes
    case graphite
    case paper
    case nord

    public var displayName: String {
        switch self {
        case .standard: return "Default"
        case .hermes: return "Hermes"
        case .graphite: return "Graphite"
        case .paper: return "Paper"
        case .nord: return "Nord"
        }
    }

    /// Named palettes prefer a matching `NSAppearance` so system widgets follow the chrome.
    public var prefersDark: Bool {
        switch self {
        case .standard, .paper: return false
        case .hermes, .graphite, .nord: return true
        }
    }
}

/// Settings > Appearance picker order. Light, Dark, and Match System stay the default pair.
public enum ThemeChoice: String, CaseIterable, Sendable {
    case light
    case dark
    case system
    case hermes
    case graphite
    case paper
    case nord

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "Match System"
        case .hermes: return "Hermes"
        case .graphite: return "Graphite"
        case .paper: return "Paper"
        case .nord: return "Nord"
        }
    }

    public var colorTheme: ColorTheme {
        switch self {
        case .light, .dark, .system: return .standard
        case .hermes: return .hermes
        case .graphite: return .graphite
        case .paper: return .paper
        case .nord: return .nord
        }
    }

    public var appearance: AppearancePreference {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return .system
        case .hermes, .graphite, .nord: return .dark
        case .paper: return .light
        }
    }

    public var settingsIdentifier: String {
        switch self {
        case .light: return "wyvern.settings.lightAppearance"
        case .dark: return "wyvern.settings.appearance.dark"
        case .system: return "wyvern.settings.appearance.system"
        case .hermes: return "wyvern.settings.appearance.hermes"
        case .graphite: return "wyvern.settings.appearance.graphite"
        case .paper: return "wyvern.settings.appearance.paper"
        case .nord: return "wyvern.settings.appearance.nord"
        }
    }

    public static func current(appearance: AppearancePreference, colorTheme: ColorTheme) -> ThemeChoice {
        switch colorTheme {
        case .hermes: return .hermes
        case .graphite: return .graphite
        case .paper: return .paper
        case .nord: return .nord
        case .standard:
            switch appearance {
            case .light: return .light
            case .dark: return .dark
            case .system: return .system
            }
        }
    }
}
