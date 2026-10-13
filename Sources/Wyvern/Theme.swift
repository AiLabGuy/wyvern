// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

/// Shared geometry for the Graphite Depth window. The tab strip and the toolbar are separate rows.
enum MonoMetrics {
    static let windowRadius: CGFloat = 12
    static let stripHeight: CGFloat = 38
    static let toolbarHeight: CGFloat = 44
    /// The strip. Traffic-light midlines match this row, not the toolbar under it.
    static let barHeight: CGFloat = 38
    static let backdropHeight: CGFloat = 82
    static let trafficLeading: CGFloat = 16
    static let trafficGap: CGFloat = 8
    static let trafficSize: CGFloat = 12
    static let trafficTrailing: CGFloat = 14
    /// 16 + 12 + 8 + 12 + 8 + 12 + 14. Tabs start after the system lights.
    static let contentLeading: CGFloat = 82
    static let toolbarPadding: CGFloat = 10
    static let control: CGFloat = 30
    static let controlRadius: CGFloat = 7
    static let itemGap: CGFloat = 4
    static let urlWidth: CGFloat = 430
    static let urlHeight: CGFloat = 32
    static let urlRadius: CGFloat = 9
    static let urlPadding: CGFloat = 12
    static let fieldGap: CGFloat = 8
    static let dividerWidth: CGFloat = 1
    static let dividerHeight: CGFloat = 22
    static let dividerSideSpace: CGFloat = 10
    static let tabWidth: CGFloat = 200
    static let tabHeight: CGFloat = 30
    static let tabRadius: CGFloat = 8
    static let tabGap: CGFloat = 2
    static let tabPadding: CGFloat = 10
    static let tabInnerGap: CGFloat = 8
    static let tabIcon: CGFloat = 14
    static let tabLabel: CGFloat = 12
    static let favicon: CGFloat = 18
    static let faviconRadius: CGFloat = 5
    static let closeIcon: CGFloat = 16
    static let closeHit: CGFloat = 28
    /// Terminal tab title. Mono, smaller than a web tab label.
    static let terminalLabel: CGFloat = 11.5
    static let starHit: CGFloat = 28
    static let starGlyph: CGFloat = 16
    static let navGlyph: CGFloat = 16
    static let plusGlyph: CGFloat = 14
    static let lockIcon: CGFloat = 13
    static let netHealthBadgeHeight: CGFloat = 24
    static let netHealthBadgeRadius: CGFloat = 12
    static let netHealthPanelWidth: CGFloat = 300
    static let barTrailing: CGFloat = 8
    static let sidebarWidth: CGFloat = 240
    /// S1 settings sidebar, including the Terminal row.
    static let settingsSidebarWidth: CGFloat = 196
    static let filterHeight: CGFloat = 28
    static let searchWidth: CGFloat = 280
    static let tileBox: CGFloat = 56
    static let tileBadge: CGFloat = 22
    static let tileBadgeRadius: CGFloat = 6
    static let tileBadgeFont: CGFloat = 13
    static let tileWidth: CGFloat = 96
    static let tileGap: CGFloat = 16
    static let newTabFieldWidth: CGFloat = 620
    static let newTabFieldHeight: CGFloat = 44
    static let newTabFieldRadius: CGFloat = 12
    static let columnGap: CGFloat = 28
    static let pagePaddingH: CGFloat = 48
    static let pagePaddingV: CGFloat = 36
    static let headerGap: CGFloat = 12
    static let headerBottom: CGFloat = 20
}

/// Graphite Depth. Each color follows the view's effective appearance.
@MainActor
enum Theme {
    static let background = token("wyvern.background", \.background)
    static let win = background
    static let bar = token("wyvern.bar", \.bar1)
    static let bar1 = bar
    static let bar2 = token("wyvern.bar2", \.bar2)
    static let tab = token("wyvern.tab", \.tab)
    static let tabA1 = token("wyvern.tabA1", \.tabA1)
    static let tabA2 = tab
    static let text = token("wyvern.text", \.text)
    static let mute = token("wyvern.mute", \.mute)
    static let line = token("wyvern.line", \.line)
    static let accent = token("wyvern.accent", \.accent)
    /// Primary fill. Dark mode uses #4C6FE0 so white text is not drawn on #7C9CFF.
    static let accentFill = token("wyvern.accentFill", \.accentFill)
    static let field = token("wyvern.field", \.field)
    static let page = token("wyvern.page", \.page)
    static let card = token("wyvern.card", \.card)
    static let barLine = tokenAlpha("wyvern.barLine", color: \.barLine, alpha: \.barLineAlpha)
    static let highlight = tokenAlpha("wyvern.highlight", color: \.highlight, alpha: \.highlightAlpha)
    static let fieldLine = tokenAlpha("wyvern.fieldLine", color: \.fieldLine, alpha: \.fieldLineAlpha)
    static let termTab = token("wyvern.termTab", \.termTab)
    static let termTabActive = token("wyvern.termTabActive", \.termTabActive)
    static let termGlyph = token("wyvern.termGlyph", \.termGlyph)
    static let termBackground = token("wyvern.termBackground", \.termBackground)
    static let termText = token("wyvern.termText", \.termText)
    static let termPrompt = token("wyvern.termPrompt", \.termPrompt)
    static let termDim = token("wyvern.termDim", \.termDim)
    static let termOutline = tokenAlpha("wyvern.termOutline", color: \.termOutline, alpha: \.termOutlineAlpha)
    static let destructive = color(hex: "#E5484D")

    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func color(hex: String, alpha: CGFloat = 1) -> NSColor {
        let channels = ThemeTokens.rgb(hex: hex) ?? (red: 0, green: 0, blue: 0)
        return NSColor(
            srgbRed: CGFloat(channels.red) / 255,
            green: CGFloat(channels.green) / 255,
            blue: CGFloat(channels.blue) / 255,
            alpha: alpha
        )
    }

    /// 88% of `base` mixed with white. Used as the top stop of a primary button.
    static func mixWhite(_ base: NSColor, amount: CGFloat = 0.88) -> NSColor {
        guard let rgb = base.usingColorSpace(.sRGB) else { return base }
        let white = 1 - amount
        return NSColor(
            srgbRed: rgb.redComponent * amount + white,
            green: rgb.greenComponent * amount + white,
            blue: rgb.blueComponent * amount + white,
            alpha: rgb.alphaComponent
        )
    }

    /// Primary-button stops. Dark mode is `#5A7BE6` over `#4C6FE0` so white text is not drawn on `#7C9CFF`.
    /// Light mode stays the accent fill with a lighter top stop.
    static func primaryButtonColors(matching appearance: NSAppearance) -> (top: NSColor, bottom: NSColor) {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark {
            return (color(hex: "#5A7BE6"), color(hex: "#4C6FE0"))
        }
        let fill = color(hex: ThemeTokens.light.accentFill)
        return (mixWhite(fill), fill)
    }

    /// `top` is the upper stop. AppKit's 90° axis runs bottom to top, so the bottom color starts the gradient.
    static func fillGradient(top: NSColor, bottom: NSColor, path: NSBezierPath) {
        if let gradient = NSGradient(starting: bottom, ending: top) {
            gradient.draw(in: path, angle: 90)
        } else {
            top.setFill()
            path.fill()
        }
    }

    static func fillBarGradient(in rect: NSRect) {
        fillGradient(top: bar1, bottom: bar2, path: NSBezierPath(rect: rect))
    }

    /// Active-tab fill plus a short drop and a top hairline. The strip clips a larger blur.
    static func fillRaisedTab(top: NSColor, bottom: NSColor, path: NSBezierPath, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.set()
        fillGradient(top: top, bottom: bottom, path: path)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.16).setFill()
        let inset = min(8, rect.width / 4)
        NSRect(x: rect.minX + inset, y: rect.maxY - 1, width: max(0, rect.width - inset * 2), height: 1).fill()
    }

    static func tabPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let radius = min(radius, min(rect.width, rect.height) / 2)
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: 0,
            endAngle: 90
        )
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: 90,
            endAngle: 180
        )
        path.close()
        return path
    }

    private static func token(
        _ name: String,
        _ key: KeyPath<ThemeTokens.Palette, String>
    ) -> NSColor {
        dynamic(name, ThemeTokens.light[keyPath: key], ThemeTokens.dark[keyPath: key])
    }

    private static func tokenAlpha(
        _ name: String,
        color: KeyPath<ThemeTokens.Palette, String>,
        alpha: KeyPath<ThemeTokens.Palette, Double>
    ) -> NSColor {
        dynamic(
            name,
            ThemeTokens.light[keyPath: color],
            ThemeTokens.dark[keyPath: color],
            lightAlpha: CGFloat(ThemeTokens.light[keyPath: alpha]),
            darkAlpha: CGFloat(ThemeTokens.dark[keyPath: alpha])
        )
    }

    private static func dynamic(
        _ name: String,
        _ light: String,
        _ dark: String,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: NSColor.Name(name), dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            let darkMode = match == .darkAqua
            return color(hex: darkMode ? dark : light, alpha: darkMode ? darkAlpha : lightAlpha)
        })
    }
}

@MainActor
enum AppearanceController {
    static func apply(_ preference: AppearancePreference) {
        switch preference {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static func currentName() -> String {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .aqua ? "light" : "dark"
    }
}

@MainActor
enum FieldFrame {
    static func draw(in rect: NSRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        Theme.field.setFill()
        path.fill()
        Theme.fieldLine.setStroke()
        path.lineWidth = 1
        path.stroke()
        Theme.barLine.setFill()
        NSRect(x: rect.minX + radius, y: rect.maxY - 2, width: max(0, rect.width - radius * 2), height: 1).fill()
    }
}

@MainActor
final class PageBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.page.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Borders and mute text. Increase Contrast and Reduce Transparency thicken rules and lift mute ink.
@MainActor
enum SettingsContrast {
    static var strong: Bool {
        let workspace = NSWorkspace.shared
        return workspace.accessibilityDisplayShouldIncreaseContrast
            || workspace.accessibilityDisplayShouldReduceTransparency
    }

    static var lineWidth: CGFloat { strong ? 1.5 : 1 }

    static var mute: NSColor {
        if strong {
            return Theme.text.withAlphaComponent(0.8)
        }
        return Theme.mute
    }
}

/// Primary, secondary, and ghost buttons. White text sits on the primary stops, not on `#7C9CFF`.
@MainActor
final class DepthButton: NSButton {
    enum Kind {
        case primary
        case secondary
        case ghost
    }

    var kind: Kind = .primary {
        didSet { needsDisplay = true }
    }
    var titleColor: NSColor?
    /// Setup buttons are 32pt. Settings rows set this to 28.
    var controlHeight: CGFloat = 32 {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
        font = Theme.font(size: 13, weight: .semibold)
    }

    convenience init(title: String, kind: Kind) {
        self.init(frame: .zero)
        self.title = title
        self.kind = kind
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let font = self.font ?? Theme.font(size: 13, weight: .semibold)
        let text = (title as NSString).size(withAttributes: [.font: font])
        let pad: CGFloat = kind == .ghost ? 8 : (controlHeight <= 28 ? 12 : 16)
        return NSSize(width: ceil(text.width) + pad * 2, height: controlHeight)
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let compact = controlHeight <= 28
        let radius: CGFloat = compact ? 7 : 8
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let ink: NSColor
        NSGraphicsContext.saveGraphicsState()
        if !isEnabled {
            NSGraphicsContext.current?.cgContext.setAlpha(0.45)
        }
        switch kind {
        case .primary:
            let stops = Theme.primaryButtonColors(matching: effectiveAppearance)
            Theme.fillGradient(top: stops.top, bottom: stops.bottom, path: path)
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSRect(x: radius, y: bounds.maxY - 1, width: max(0, bounds.width - radius * 2), height: 1).fill()
            ink = titleColor ?? .white
        case .secondary:
            Theme.fillGradient(top: Theme.tabA1, bottom: Theme.tabA2, path: path)
            Theme.fieldLine.setStroke()
            path.lineWidth = SettingsContrast.lineWidth
            path.stroke()
            ink = titleColor ?? Theme.text
        case .ghost:
            ink = titleColor ?? SettingsContrast.mute
        }
        let font = self.font ?? Theme.font(size: 13, weight: .semibold)
        let rendered = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: ink
        ])
        let size = rendered.size()
        let rect = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        rendered.draw(with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self {
            Theme.accent.setStroke()
            let inset: CGFloat = compact ? 2 : 1
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Settings rows, Import, and the network-health Trace button. Shorter than a setup action.
    func applySettingsStyle() {
        controlHeight = 28
        font = Theme.font(size: 12.5, weight: .semibold)
    }
}

/// Settings Import buttons and the same 28pt secondary buttons elsewhere.
@MainActor
func styleSettingsButton(_ button: DepthButton) {
    button.controlHeight = 28
    button.font = Theme.font(size: 12.5, weight: .semibold)
}
