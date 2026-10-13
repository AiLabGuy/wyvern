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
}
