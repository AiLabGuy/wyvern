// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit

/// Toolbar Split View control. A short click runs `onPress`. Holding for 300 ms runs `onLongPress`
/// and does not also run the click. Tracking stays in `.eventTracking` so the hold timer fires
/// during the mouse-down loop.
@MainActor
final class SplitViewButton: ToolButton {
    var onPress: (() -> Void)?
    var onLongPress: (() -> Void)?

    private var holdTimer: Timer?
    private var firedHold = false

    override func mouseDown(with event: NSEvent) {
        firedHold = false
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.firedHold = true
                self.onLongPress?()
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        holdTimer = timer
        if let window {
            var current: NSEvent? = event
            while let tracked = current, tracked.type != .leftMouseUp {
                current = window.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: Date.distantFuture,
                    inMode: .eventTracking,
                    dequeue: true
                )
            }
        }
        timer.invalidate()
        holdTimer = nil
        if !firedHold {
            onPress?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// One layout tile in the press-and-hold popover. 44×30, radius 6, 2 px accent ring when selected.
@MainActor
final class SplitLayoutButton: NSButton {
    var arrangement: TileArrangement = .twoColumns
    var picked = false {
        didSet {
            needsDisplay = true
            applyAccessibility()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .shadowlessSquare
        setButtonType(.momentaryPushIn)
        imagePosition = .noImage
        focusRingType = .none
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyAccessibility() {
        let name = arrangement.accessibilityName
        let label = picked ? "Layout: \(name), selected" : "Layout: \(name)"
        setAccessibilityLabel(label)
        toolTip = label
    }

    override func draw(_ dirtyRect: NSRect) {
        let cells = Self.cells(for: arrangement, in: bounds.insetBy(dx: 7, dy: 6))
        for cell in cells {
            let path = NSBezierPath(roundedRect: cell, xRadius: 2, yRadius: 2)
            Theme.field.setFill()
            path.fill()
            Theme.line.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        if picked {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            Theme.accent.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// AppKit's origin is the bottom-left. The first cell of a vertical layout is the top one.
    private static func cells(for arrangement: TileArrangement, in rect: NSRect) -> [NSRect] {
        let gap: CGFloat = 2
        switch arrangement {
        case .twoColumns:
            let width = (rect.width - gap) / 2
            return [
                NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                NSRect(x: rect.minX + width + gap, y: rect.minY, width: width, height: rect.height)
            ]
        case .twoRows:
            let height = (rect.height - gap) / 2
            return [
                NSRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height),
                NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            ]
        case .threeColumns:
            let width = (rect.width - gap * 2) / 3
            return (0..<3).map { index in
                NSRect(
                    x: rect.minX + CGFloat(index) * (width + gap),
                    y: rect.minY,
                    width: width,
                    height: rect.height
                )
            }
        case .grid:
            let width = (rect.width - gap) / 2
            let height = (rect.height - gap) / 2
            return [
                NSRect(x: rect.minX, y: rect.maxY - height, width: width, height: height),
                NSRect(x: rect.minX + width + gap, y: rect.maxY - height, width: width, height: height),
                NSRect(x: rect.minX, y: rect.minY, width: width, height: height),
                NSRect(x: rect.minX + width + gap, y: rect.minY, width: width, height: height)
            ]
        case .onePlusTwo:
            let width = (rect.width - gap) / 2
            let height = (rect.height - gap) / 2
            return [
                NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                NSRect(x: rect.minX + width + gap, y: rect.maxY - height, width: width, height: height),
                NSRect(x: rect.minX + width + gap, y: rect.minY, width: width, height: height)
            ]
        }
    }
}

/// Five layout tiles. The spec text says "4 tiles" and then lists five layouts; this shows all five.
@MainActor
final class SplitLayoutPicker: NSView {
    var onChoose: ((TileArrangement) -> Void)?
    var selected: TileArrangement? {
        didSet { refreshSelection() }
    }

    private var buttons: [SplitLayoutButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityElement(false)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        for arrangement in TileArrangement.allCases {
            let button = SplitLayoutButton(frame: .zero)
            button.arrangement = arrangement
            button.picked = false
            button.applyAccessibility()
            button.target = self
            button.action = #selector(picked(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 30)
            ])
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Layouts")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func refreshSelection() {
        for button in buttons {
            button.picked = button.arrangement == selected
        }
    }

    @objc private func picked(_ sender: SplitLayoutButton) {
        onChoose?(sender.arrangement)
    }
}
