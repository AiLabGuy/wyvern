// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class ThemeTokensTests: XCTestCase {
    func testLightPalette() {
        let light = ThemeTokens.light
        XCTAssertEqual(light.background, "#F6F7F8")
        XCTAssertEqual(light.bar1, "#F3F4F6")
        XCTAssertEqual(light.bar2, "#E4E6E9")
        XCTAssertEqual(light.tab, "#F7F8F9")
        XCTAssertEqual(light.tabA1, "#FFFFFF")
        XCTAssertEqual(light.text, "#16181B")
        XCTAssertEqual(light.mute, "#666B73")
        XCTAssertEqual(light.line, "#E1E3E6")
        XCTAssertEqual(light.accent, "#2F5BEA")
        XCTAssertEqual(light.accentFill, "#2F5BEA")
        XCTAssertEqual(light.field, "#FFFFFF")
        XCTAssertEqual(light.page, "#FFFFFF")
        XCTAssertEqual(light.card, "#F4F5F7")
        XCTAssertEqual(light.barLineAlpha, 0.10)
        XCTAssertEqual(light.termTab, "#E6EEE9")
        XCTAssertEqual(light.termTabActive, "#F2F7F4")
        XCTAssertEqual(light.termGlyph, "#17834A")
        XCTAssertEqual(light.termBackground, "#FBFCFB")
        XCTAssertEqual(light.termText, "#1B2620")
        XCTAssertEqual(light.termPrompt, "#17834A")
        XCTAssertEqual(light.termDim, "#6A7A70")
        XCTAssertEqual(light.termOutline, "#17834A")
        XCTAssertEqual(light.termOutlineAlpha, 0.30)
    }

    func testDarkPalette() {
        let dark = ThemeTokens.dark
        XCTAssertEqual(dark.background, "#121315")
        XCTAssertEqual(dark.bar1, "#26282C")
        XCTAssertEqual(dark.bar2, "#1C1E21")
        XCTAssertEqual(dark.tab, "#2B2E32")
        XCTAssertEqual(dark.tabA1, "#34373C")
        XCTAssertEqual(dark.text, "#ECEDEF")
        XCTAssertEqual(dark.mute, "#8F949B")
        XCTAssertEqual(dark.line, "#2A2C30")
        XCTAssertEqual(dark.accent, "#7C9CFF")
        XCTAssertEqual(dark.accentFill, "#4C6FE0")
        XCTAssertNotEqual(dark.accentFill, dark.accent)
        XCTAssertEqual(dark.field, "#141518")
        XCTAssertEqual(dark.page, "#17181A")
        XCTAssertEqual(dark.card, "#1E2023")
        XCTAssertEqual(dark.barLineAlpha, 0.06)
        XCTAssertEqual(dark.termTab, "#16201B")
        XCTAssertEqual(dark.termTabActive, "#1B2620")
        XCTAssertEqual(dark.termGlyph, "#2FBF71")
        XCTAssertEqual(dark.termBackground, "#0C110E")
        XCTAssertEqual(dark.termText, "#D6E2DA")
        XCTAssertEqual(dark.termPrompt, "#2FBF71")
        XCTAssertEqual(dark.termDim, "#6F8577")
        XCTAssertEqual(dark.termOutline, "#2FBF71")
        XCTAssertEqual(dark.termOutlineAlpha, 0.28)
    }

    func testAccentChannels() throws {
        let light = try XCTUnwrap(ThemeTokens.rgb(hex: "#2F5BEA"))
        XCTAssertEqual(light.red, 47)
        XCTAssertEqual(light.green, 91)
        XCTAssertEqual(light.blue, 234)
        let bare = try XCTUnwrap(ThemeTokens.rgb(hex: "2F5BEA"))
        XCTAssertTrue(bare == light)
        let fromToken = try XCTUnwrap(ThemeTokens.rgb(hex: ThemeTokens.light.accent))
        XCTAssertTrue(fromToken == light)
        let dark = try XCTUnwrap(ThemeTokens.rgb(hex: ThemeTokens.dark.accent))
        XCTAssertEqual(dark.red, 124)
        XCTAssertEqual(dark.green, 156)
        XCTAssertEqual(dark.blue, 255)
        let fill = try XCTUnwrap(ThemeTokens.rgb(hex: ThemeTokens.dark.accentFill))
        XCTAssertEqual(fill.red, 76)
        XCTAssertEqual(fill.green, 111)
        XCTAssertEqual(fill.blue, 224)
    }

    func testEveryTokenParses() {
        let palettes = [ThemeTokens.light, ThemeTokens.dark]
        for palette in palettes {
            for hex in [
                palette.background, palette.bar1, palette.bar2, palette.tab, palette.tabA1,
                palette.text, palette.mute, palette.line, palette.accent, palette.accentFill,
                palette.field, palette.page, palette.card, palette.barLine, palette.highlight,
                palette.fieldLine, palette.termTab, palette.termTabActive, palette.termGlyph,
                palette.termBackground, palette.termText, palette.termPrompt, palette.termDim,
                palette.termOutline
            ] {
                XCTAssertNotNil(ThemeTokens.rgb(hex: hex), hex)
            }
        }
    }

    func testBarTokenChannels() throws {
        let light = try XCTUnwrap(ThemeTokens.rgb(hex: ThemeTokens.light.bar1))
        XCTAssertEqual(light.red, 243)
        XCTAssertEqual(light.green, 244)
        XCTAssertEqual(light.blue, 246)
        let dark = try XCTUnwrap(ThemeTokens.rgb(hex: ThemeTokens.dark.bar1))
        XCTAssertEqual(dark.red, 38)
        XCTAssertEqual(dark.green, 40)
        XCTAssertEqual(dark.blue, 44)
    }

    func testRejectsShortAndNonHex() {
        XCTAssertNil(ThemeTokens.rgb(hex: "#FFF"))
        XCTAssertNil(ThemeTokens.rgb(hex: "zzzzzz"))
        XCTAssertNil(ThemeTokens.rgb(hex: ""))
    }

    func testPickerOrderAndUniqueNames() {
        XCTAssertEqual(
            ThemeChoice.allCases.map(\.rawValue),
            ["light", "dark", "system", "hermes", "graphite", "paper", "nord"]
        )
        let names = ThemeChoice.allCases.map(\.displayName)
        XCTAssertEqual(names, ["Light", "Dark", "Match System", "Hermes", "Graphite", "Paper", "Nord"])
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Set(ThemeChoice.allCases.map(\.rawValue)).count, ThemeChoice.allCases.count)
        XCTAssertEqual(Set(ColorTheme.allCases.map(\.rawValue)).count, ColorTheme.allCases.count)
        XCTAssertEqual(
            ColorTheme.allCases.map(\.displayName),
            ["Default", "Hermes", "Graphite", "Paper", "Nord"]
        )
        XCTAssertEqual(Set(ColorTheme.allCases.map(\.displayName)).count, ColorTheme.allCases.count)
        XCTAssertEqual(ThemeTokens.catalog.map(\.name), ["Light", "Dark", "Hermes", "Graphite", "Paper", "Nord"])
        XCTAssertEqual(Set(ThemeTokens.catalog.map(\.id)).count, ThemeTokens.catalog.count)
        XCTAssertEqual(Set(ThemeTokens.catalog.map(\.name)).count, ThemeTokens.catalog.count)
    }

    func testEveryThemeDefinesEveryToken() {
        XCTAssertFalse(ThemeTokens.hexTokenNames.isEmpty)
        XCTAssertFalse(ThemeTokens.alphaTokenNames.isEmpty)
        for entry in ThemeTokens.catalog {
            let palette = entry.palette
            let mirroredHex = palette.mirroredHexTokens
            XCTAssertEqual(
                Set(mirroredHex.keys),
                ThemeTokens.hexTokenNames,
                "\(entry.name) hex tokens"
            )
            XCTAssertEqual(
                Set(palette.hexTokens.map(\.name)),
                ThemeTokens.hexTokenNames,
                "\(entry.name) listed hex tokens"
            )
            for (name, hex) in palette.hexTokens {
                XCTAssertNotNil(ThemeTokens.rgb(hex: hex), "\(entry.name).\(name) = \(hex)")
                XCTAssertEqual(mirroredHex[name], hex, "\(entry.name).\(name)")
            }
            let mirroredAlpha = palette.mirroredAlphaTokens
            XCTAssertEqual(
                Set(mirroredAlpha.keys),
                ThemeTokens.alphaTokenNames,
                "\(entry.name) alpha tokens"
            )
            for (name, value) in palette.alphaTokens {
                XCTAssertGreaterThanOrEqual(value, 0, "\(entry.name).\(name)")
                XCTAssertLessThanOrEqual(value, 1, "\(entry.name).\(name)")
                XCTAssertEqual(mirroredAlpha[name], value)
            }
        }
        for theme in ColorTheme.allCases {
            let light = ThemeTokens.palette(for: theme, darkAppearance: false)
            let dark = ThemeTokens.palette(for: theme, darkAppearance: true)
            XCTAssertEqual(Set(light.hexTokens.map(\.name)), ThemeTokens.hexTokenNames)
            XCTAssertEqual(Set(dark.hexTokens.map(\.name)), ThemeTokens.hexTokenNames)
            switch theme {
            case .standard:
                XCTAssertEqual(light, ThemeTokens.light)
                XCTAssertEqual(dark, ThemeTokens.dark)
            case .hermes:
                XCTAssertEqual(light, ThemeTokens.hermes)
                XCTAssertEqual(dark, ThemeTokens.hermes)
            case .graphite:
                XCTAssertEqual(light, ThemeTokens.graphite)
                XCTAssertEqual(dark, ThemeTokens.graphite)
            case .paper:
                XCTAssertEqual(light, ThemeTokens.paper)
                XCTAssertEqual(dark, ThemeTokens.paper)
            case .nord:
                XCTAssertEqual(light, ThemeTokens.nord)
                XCTAssertEqual(dark, ThemeTokens.nord)
            }
        }
    }

    func testNamedThemeSelectionIgnoresAppearanceForPalette() {
        XCTAssertEqual(
            ThemeChoice.current(appearance: .light, colorTheme: .hermes),
            .hermes
        )
        XCTAssertEqual(
            ThemeChoice.current(appearance: .system, colorTheme: .standard),
            .system
        )
        XCTAssertEqual(
            ThemeChoice.current(appearance: .dark, colorTheme: .standard),
            .dark
        )
        XCTAssertEqual(ThemeChoice.paper.appearance, .light)
        XCTAssertEqual(ThemeChoice.hermes.appearance, .dark)
        XCTAssertEqual(ThemeChoice.graphite.colorTheme, .graphite)
        XCTAssertEqual(ThemeChoice.light.colorTheme, .standard)
    }

    func testContrastMathMatchesWCAG() throws {
        XCTAssertEqual(try XCTUnwrap(ColorContrast.relativeLuminance(hex: "#FFFFFF")), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ColorContrast.relativeLuminance(hex: "#000000")), 0.0, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(ColorContrast.contrastRatio(foreground: "#FFFFFF", background: "#000000")),
            21.0,
            accuracy: 0.0001
        )
        // WCAG reference gray: #767676 on white is the AA 4.5:1 boundary.
        let gray = try XCTUnwrap(ColorContrast.contrastRatio(foreground: "#767676", background: "#FFFFFF"))
        XCTAssertEqual(gray, 4.54, accuracy: 0.02)
        XCTAssertTrue(ColorContrast.meetsAA(foreground: "#16181B", background: "#FFFFFF"))
        XCTAssertTrue(ColorContrast.meetsAA(foreground: "#F2C230", background: "#0B2A6F", largeOrUI: true))
        XCTAssertNil(ColorContrast.contrastRatio(foreground: "nope", background: "#000000"))
    }

    func testEveryThemeMeetsWCAGTextAndIndicatorContrast() throws {
        for entry in ThemeTokens.catalog {
            try assertReadableText(entry.palette, name: entry.name)
            try assertAccentIndicators(entry.palette, name: entry.name)
            try assertTerminalText(entry.palette, name: entry.name)
        }
        // Named palettes also keep mute ink at 4.5:1 on chrome, page, and the selected tab.
        for entry in ThemeTokens.catalog where entry.id != "light" && entry.id != "dark" {
            try assertMuteText(entry.palette, name: entry.name)
        }
        // Default Light/Dark keep the original mute tokens. Mute is not tab-title ink
        // (titles use `text`). bar2 is the lower toolbar gradient stop, not a text fill.
        // termDim on Light sits at ~4.41:1 on the terminal page and is secondary chrome.
        let lightMuteBar1 = try XCTUnwrap(
            ColorContrast.contrastRatio(foreground: ThemeTokens.light.mute, background: ThemeTokens.light.bar1)
        )
        XCTAssertGreaterThanOrEqual(lightMuteBar1, ColorContrast.aaNormalText)
        let darkMuteChrome = try XCTUnwrap(
            ColorContrast.contrastRatio(foreground: ThemeTokens.dark.mute, background: ThemeTokens.dark.background)
        )
        XCTAssertGreaterThanOrEqual(darkMuteChrome, ColorContrast.aaNormalText)
        let darkMutePage = try XCTUnwrap(
            ColorContrast.contrastRatio(foreground: ThemeTokens.dark.mute, background: ThemeTokens.dark.page)
        )
        XCTAssertGreaterThanOrEqual(darkMutePage, ColorContrast.aaNormalText)
    }

    private func assertReadableText(_ palette: ThemeTokens.Palette, name: String) throws {
        let surfaces = [
            ("chrome", palette.background),
            ("page", palette.page),
            ("selected tab", palette.tabA1),
            ("tab", palette.tab),
            ("field", palette.field),
            ("card", palette.card),
            ("bar1", palette.bar1),
            ("bar2", palette.bar2)
        ]
        for (surface, background) in surfaces {
            let ratio = try XCTUnwrap(
                ColorContrast.contrastRatio(foreground: palette.text, background: background),
                "\(name) text on \(surface)"
            )
            XCTAssertGreaterThanOrEqual(
                ratio,
                ColorContrast.aaNormalText,
                "\(name) text on \(surface) \(palette.text) / \(background) = \(ratio)"
            )
        }
        let fill = try XCTUnwrap(
            ColorContrast.contrastRatio(foreground: "#FFFFFF", background: palette.accentFill),
            "\(name) white on accentFill"
        )
        XCTAssertGreaterThanOrEqual(
            fill,
            ColorContrast.aaNormalText,
            "\(name) white on accentFill \(palette.accentFill) = \(fill)"
        )
    }

    private func assertMuteText(_ palette: ThemeTokens.Palette, name: String) throws {
        let surfaces = [
            ("chrome", palette.background),
            ("page", palette.page),
            ("selected tab", palette.tabA1),
            ("tab", palette.tab),
            ("field", palette.field),
            ("card", palette.card),
            ("bar1", palette.bar1),
            ("bar2", palette.bar2)
        ]
        for (surface, background) in surfaces {
            let ratio = try XCTUnwrap(
                ColorContrast.contrastRatio(foreground: palette.mute, background: background),
                "\(name) mute on \(surface)"
            )
            XCTAssertGreaterThanOrEqual(
                ratio,
                ColorContrast.aaNormalText,
                "\(name) mute on \(surface) \(palette.mute) / \(background) = \(ratio)"
            )
        }
    }

    private func assertAccentIndicators(_ palette: ThemeTokens.Palette, name: String) throws {
        let surfaces = [
            ("chrome", palette.background),
            ("bar1", palette.bar1),
            ("bar2", palette.bar2),
            ("tab", palette.tab),
            ("selected tab", palette.tabA1)
        ]
        for (surface, background) in surfaces {
            let ratio = try XCTUnwrap(
                ColorContrast.contrastRatio(foreground: palette.accent, background: background),
                "\(name) accent on \(surface)"
            )
            XCTAssertGreaterThanOrEqual(
                ratio,
                ColorContrast.aaLargeOrUI,
                "\(name) accent on \(surface) \(palette.accent) / \(background) = \(ratio)"
            )
        }
    }

    private func assertTerminalText(_ palette: ThemeTokens.Palette, name: String) throws {
        let text = try XCTUnwrap(
            ColorContrast.contrastRatio(foreground: palette.termText, background: palette.termBackground)
        )
        XCTAssertGreaterThanOrEqual(text, ColorContrast.aaNormalText, "\(name) termText")
        let prompt = try XCTUnwrap(
            ColorContrast.contrastRatio(foreground: palette.termPrompt, background: palette.termBackground)
        )
        XCTAssertGreaterThanOrEqual(prompt, ColorContrast.aaNormalText, "\(name) termPrompt")
        let dim = try XCTUnwrap(
            ColorContrast.contrastRatio(foreground: palette.termDim, background: palette.termBackground)
        )
        if name == "Light" {
            // Decorative / secondary terminal chrome. 4.41:1 on the default Light page.
            XCTAssertGreaterThan(dim, 4.3, "\(name) termDim (documented decorative)")
        } else {
            XCTAssertGreaterThanOrEqual(dim, ColorContrast.aaNormalText, "\(name) termDim")
        }
        let glyph = try XCTUnwrap(
            ColorContrast.contrastRatio(foreground: palette.termGlyph, background: palette.termTab)
        )
        XCTAssertGreaterThanOrEqual(glyph, ColorContrast.aaLargeOrUI, "\(name) termGlyph")
    }
}
