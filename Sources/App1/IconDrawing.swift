// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import App1Core
import AppKit

/// 16px stroke icons. Coordinates match the viewBox with y growing downward; drawing flips into the box.
enum IconGlyph: Equatable {
    case back
    case forward
    case reload
    case star
    case plus
    case close
    case sidebar
    case lock
    case search
    case download
    case folder
    case bookmark
    case moon
    case activity
    /// Settings sidebar: Appearance.
    case sun
    /// Settings sidebar: General.
    case dial
    /// Terminal tab and settings.
    case terminal
    case pencil
    case trash
}

enum IconDrawing {
    /// Template image of one glyph, for stock `NSButton`s. `contentTintColor` colors it.
    static func templateImage(_ glyph: IconGlyph, pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            IconDrawing.stroke(glyph, in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// `box` is in a non-flipped view (y grows upward).
    static func stroke(_ glyph: IconGlyph, in box: NSRect, color: NSColor) {
        let scale = box.width / 16
        guard scale > 0 else { return }
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: box.minX + x * scale, y: box.maxY - y * scale)
        }
        func svgRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(
                x: box.minX + x * scale,
                y: box.maxY - (y + height) * scale,
                width: width * scale,
                height: height * scale
            )
        }
        func paint(_ path: NSBezierPath) {
            path.lineWidth = 1.5 * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }
        func arc(cx: CGFloat, cy: CGFloat, radius: CGFloat, start: CGFloat, sweep: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            let steps = 48
            for step in 0...steps {
                let degrees = start + sweep * CGFloat(step) / CGFloat(steps)
                let radians = degrees * .pi / 180
                let point = p(cx + radius * cos(radians), cy + radius * sin(radians))
                if step == 0 {
                    path.move(to: point)
                } else {
                    path.line(to: point)
                }
            }
            return path
        }

        switch glyph {
        case .back:
            let path = NSBezierPath()
            path.move(to: p(10, 3))
            path.line(to: p(5, 8))
            path.line(to: p(10, 13))
            paint(path)
        case .forward:
            let path = NSBezierPath()
            path.move(to: p(6, 3))
            path.line(to: p(11, 8))
            path.line(to: p(6, 13))
            paint(path)
        case .reload:
            // Almost a full turn, clockwise on screen, leaving the gap at the upper right.
            paint(arc(cx: 8, cy: 8, radius: 5, start: 0, sweep: 314.15))
            let arrow = NSBezierPath()
            arrow.move(to: p(13, 3))
            arrow.line(to: p(13, 5.5))
            arrow.line(to: p(10.5, 5.5))
            paint(arrow)
        case .star:
            let path = NSBezierPath()
            path.move(to: p(8, 2))
            path.line(to: p(9.8, 5.8))
            path.line(to: p(14, 6.3))
            path.line(to: p(10.9, 9.2))
            path.line(to: p(11.7, 13.3))
            path.line(to: p(8, 11.3))
            path.line(to: p(4.3, 13.3))
            path.line(to: p(5.1, 9.2))
            path.line(to: p(2, 6.3))
            path.line(to: p(6.2, 5.8))
            path.close()
            paint(path)
        case .plus:
            let path = NSBezierPath()
            path.move(to: p(8, 3))
            path.line(to: p(8, 13))
            path.move(to: p(3, 8))
            path.line(to: p(13, 8))
            paint(path)
        case .close:
            let path = NSBezierPath()
            path.move(to: p(4.5, 4.5))
            path.line(to: p(11.5, 11.5))
            path.move(to: p(11.5, 4.5))
            path.line(to: p(4.5, 11.5))
            paint(path)
        case .sidebar:
            paint(NSBezierPath(roundedRect: svgRect(2, 3, 12, 10), xRadius: 2 * scale, yRadius: 2 * scale))
            let path = NSBezierPath()
            path.move(to: p(6, 3))
            path.line(to: p(6, 13))
            paint(path)
        case .lock:
            paint(NSBezierPath(roundedRect: svgRect(4, 7, 8, 6), xRadius: 1.5 * scale, yRadius: 1.5 * scale))
            let shackle = arc(cx: 8, cy: 5.5, radius: 2.5, start: 180, sweep: 180)
            let stem = NSBezierPath()
            stem.move(to: p(5.5, 7))
            stem.line(to: p(5.5, 5.5))
            stem.append(shackle)
            stem.line(to: p(10.5, 7))
            paint(stem)
        case .search:
            paint(NSBezierPath(ovalIn: svgRect(3, 3, 8, 8)))
            let path = NSBezierPath()
            path.move(to: p(10, 10))
            path.line(to: p(13.5, 13.5))
            paint(path)
        case .download:
            let arrow = NSBezierPath()
            arrow.move(to: p(8, 2.5))
            arrow.line(to: p(8, 10))
            arrow.move(to: p(5, 7.2))
            arrow.line(to: p(8, 10.5))
            arrow.line(to: p(11, 7.2))
            paint(arrow)
            let tray = NSBezierPath()
            tray.move(to: p(3, 11))
            tray.line(to: p(3, 13.5))
            tray.line(to: p(13, 13.5))
            tray.line(to: p(13, 11))
            paint(tray)
        case .folder:
            let tab = NSBezierPath()
            tab.move(to: p(2.5, 6.5))
            tab.line(to: p(2.5, 5.5))
            tab.line(to: p(6, 5.5))
            tab.line(to: p(7.2, 4.2))
            tab.line(to: p(11, 4.2))
            paint(tab)
            paint(NSBezierPath(roundedRect: svgRect(2.5, 6, 11, 7.5), xRadius: 1.5 * scale, yRadius: 1.5 * scale))
        case .bookmark:
            let path = NSBezierPath()
            path.move(to: p(4, 2))
            path.line(to: p(4, 14))
            path.line(to: p(8, 11))
            path.line(to: p(12, 14))
            path.line(to: p(12, 2))
            path.close()
            paint(path)
        case .moon:
            paint(arc(cx: 9, cy: 8, radius: 5, start: 60, sweep: 240))
            let inner = arc(cx: 11.2, cy: 8, radius: 4.2, start: 300, sweep: -240)
            paint(inner)
        case .activity:
            let path = NSBezierPath()
            path.move(to: p(1.5, 8))
            path.line(to: p(4.2, 8))
            path.line(to: p(6, 3.5))
            path.line(to: p(9.2, 12.5))
            path.line(to: p(11.2, 8))
            path.line(to: p(14.5, 8))
            paint(path)
        case .sun:
            paint(NSBezierPath(ovalIn: svgRect(5, 5, 6, 6)))
            let rays = NSBezierPath()
            rays.move(to: p(8, 1.5))
            rays.line(to: p(8, 3))
            rays.move(to: p(8, 13))
            rays.line(to: p(8, 14.5))
            rays.move(to: p(1.5, 8))
            rays.line(to: p(3, 8))
            rays.move(to: p(13, 8))
            rays.line(to: p(14.5, 8))
            rays.move(to: p(3.4, 3.4))
            rays.line(to: p(4.4, 4.4))
            rays.move(to: p(11.6, 11.6))
            rays.line(to: p(12.6, 12.6))
            rays.move(to: p(3.4, 12.6))
            rays.line(to: p(4.4, 11.6))
            rays.move(to: p(11.6, 4.4))
            rays.line(to: p(12.6, 3.4))
            paint(rays)
        case .dial:
            paint(NSBezierPath(ovalIn: svgRect(5.8, 5.8, 4.4, 4.4)))
            let marks = NSBezierPath()
            marks.move(to: p(8, 1.8))
            marks.line(to: p(8, 3.6))
            marks.move(to: p(8, 12.4))
            marks.line(to: p(8, 14.2))
            marks.move(to: p(1.8, 8))
            marks.line(to: p(3.6, 8))
            marks.move(to: p(12.4, 8))
            marks.line(to: p(14.2, 8))
            marks.move(to: p(3.6, 3.6))
            marks.line(to: p(4.9, 4.9))
            marks.move(to: p(11.1, 11.1))
            marks.line(to: p(12.4, 12.4))
            marks.move(to: p(3.6, 12.4))
            marks.line(to: p(4.9, 11.1))
            marks.move(to: p(11.1, 4.9))
            marks.line(to: p(12.4, 3.6))
            paint(marks)
        case .terminal:
            let path = NSBezierPath()
            path.move(to: p(3, 4))
            path.line(to: p(7, 8))
            path.line(to: p(3, 12))
            path.move(to: p(8.5, 12))
            path.line(to: p(13, 12))
            paint(path)
        case .pencil:
            let path = NSBezierPath()
            path.move(to: p(10.2, 2.2))
            path.line(to: p(13.8, 5.8))
            path.line(to: p(6.2, 13.4))
            path.line(to: p(2.6, 13.4))
            path.line(to: p(2.6, 9.8))
            path.close()
            paint(path)
        case .trash:
            let path = NSBezierPath()
            path.move(to: p(3, 4.5))
            path.line(to: p(13, 4.5))
            path.move(to: p(6.2, 4.5))
            path.line(to: p(6.5, 3))
            path.line(to: p(9.5, 3))
            path.line(to: p(9.8, 4.5))
            path.move(to: p(4.4, 4.5))
            path.line(to: p(5.1, 13.2))
            path.line(to: p(10.9, 13.2))
            path.line(to: p(11.6, 4.5))
            paint(path)
        }
    }
}

@MainActor
final class GlyphView: NSView {
    var glyph: IconGlyph = .search {
        didSet { needsDisplay = true }
    }
    var tint: NSColor = Theme.mute {
        didSet { needsDisplay = true }
    }
    var pointSize: CGFloat = 16

    override func draw(_ dirtyRect: NSRect) {
        let side = min(min(bounds.width, bounds.height), pointSize)
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        IconDrawing.stroke(glyph, in: rect, color: tint)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class LetterBadgeView: NSView {
    var letter: String = "?" {
        didSet { needsDisplay = true }
    }
    var hex: String = SiteBadge.listHex {
        didSet { needsDisplay = true }
    }
    var cornerRadius: CGFloat = 4
    var fontSize: CGFloat = 9

    override func draw(_ dirtyRect: NSRect) {
        Theme.color(hex: hex).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        let font = Theme.font(size: fontSize, weight: .bold)
        let ink = Self.ink(on: hex)
        let text = NSAttributedString(string: letter, attributes: [
            .font: font,
            .foregroundColor: ink
        ])
        let size = text.size()
        let rect = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        text.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    /// White text is not drawn on the dark accent. That fill uses dark text instead.
    private static func ink(on hex: String) -> NSColor {
        var digits = hex
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        if digits.caseInsensitiveCompare("7C9CFF") == .orderedSame {
            return Theme.color(hex: "#0B1020")
        }
        return .white
    }
}

/// Icon button. A borderless `NSButton` that draws its own glyph and fill; tracking, the
/// mouse-up-inside rule, keyboard activation, and accessibility press are stock `NSButton`.
@MainActor
final class ToolButton: NSButton {
    var glyph: IconGlyph = .plus {
        didSet { needsDisplay = true }
    }
    var pointSize: CGFloat = 16 {
        didSet { needsDisplay = true }
    }
    var tint: NSColor = Theme.mute {
        didSet { needsDisplay = true }
    }
    var fill: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    var cornerRadius: CGFloat = MonoMetrics.controlRadius

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .shadowlessSquare
        setButtonType(.momentaryPushIn)
        imagePosition = .noImage
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Toolbar buttons sit under the transparent title bar. A click must not start a window drag.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        fill.setFill()
        path.fill()
        if isHighlighted {
            Theme.line.setFill()
            path.fill()
        }
        let side = pointSize
        let iconRect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let color = isEnabled ? tint : tint.withAlphaComponent(0.35)
        IconDrawing.stroke(glyph, in: iconRect, color: color)
    }

    /// A popover or sheet can be exposed as an accessibility child of the control that opened it.
    var extraAccessibilityChild: NSView?

    override func accessibilityChildren() -> [Any]? {
        var kids = super.accessibilityChildren() ?? []
        if let extraAccessibilityChild {
            kids.append(extraAccessibilityChild)
        }
        return kids
    }

    /// Right click on the new-tab button opens the terminal bookmark picker.
    var onContextMenu: (() -> Void)?

    /// Left click still sends the action through stock `NSButton` tracking.
    /// A context menu, when one is set, opens on right click.
    override func rightMouseDown(with event: NSEvent) {
        if let onContextMenu {
            onContextMenu()
            return
        }
        guard let menu else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        if let onContextMenu {
            onContextMenu()
            return true
        }
        return super.accessibilityPerformShowMenu()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class AccentTextButton: NSControl {
    var title: String = "" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var glyph: IconGlyph = .plus
    var iconSize: CGFloat = 13

    override var intrinsicContentSize: NSSize {
        let font = Theme.font(size: 13)
        let text = (title as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(12 + iconSize + 6 + text.width + 12), height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.accentFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: MonoMetrics.controlRadius, yRadius: MonoMetrics.controlRadius).fill()
        let iconRect = NSRect(x: 12, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize)
        IconDrawing.stroke(glyph, in: iconRect, color: .white)
        let font = Theme.font(size: 13, weight: .semibold)
        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
        let size = text.size()
        let rect = NSRect(
            x: 12 + iconSize + 6,
            y: bounds.midY - size.height / 2,
            width: bounds.width - 12 - iconSize - 6,
            height: size.height
        )
        text.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        sendAction(action, to: target)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class ChipLabel: NSView {
    var text: String = "" {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var fontSize: CGFloat = 11
    var monospaced = false

    override var intrinsicContentSize: NSSize {
        let font = monospaced ? Theme.mono(size: fontSize) : Theme.font(size: fontSize)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width) + 14, height: max(16, ceil(size.height) + 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.tab.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        let font = monospaced ? Theme.mono(size: fontSize) : Theme.font(size: fontSize)
        let rendered = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: Theme.mute
        ])
        let size = rendered.size()
        let rect = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        rendered.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
