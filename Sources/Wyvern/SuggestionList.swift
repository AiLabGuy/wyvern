// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

/// Address-bar and new-tab suggestion list. Rows come from `HistoryMatcher`.
@MainActor
final class SuggestionController {
    var onPick: ((HistorySuggestion) -> Void)?

    private let list = SuggestionListView()
    private weak var anchor: NSView?
    private var monitor: Any?

    var isVisible: Bool {
        list.superview != nil && !list.isHidden
    }

    func update(_ items: [HistorySuggestion], anchor: NSView) {
        self.anchor = anchor
        guard !items.isEmpty, let host = anchor.window?.contentView else {
            dismiss()
            return
        }
        list.apply(items)
        if list.superview !== host {
            host.addSubview(list, positioned: .above, relativeTo: nil)
        }
        position(anchor: anchor, host: host)
        list.isHidden = false
        installMonitor()
    }

    func reposition() {
        guard isVisible, let anchor, let host = anchor.window?.contentView else { return }
        if list.superview !== host {
            host.addSubview(list, positioned: .above, relativeTo: nil)
        }
        position(anchor: anchor, host: host)
    }

    func dismiss() {
        list.isHidden = true
        list.removeFromSuperview()
        anchor = nil
        guard let token = monitor else { return }
        monitor = nil
        // Removing a monitor from inside its own callback can drop the event. Drop it next turn.
        DispatchQueue.main.async {
            NSEvent.removeMonitor(token)
        }
    }

    /// Up/Down, Return on a highlighted row, and Escape. Return with nothing highlighted
    /// falls through so the field can still submit the typed text.
    func handle(_ commandSelector: Selector) -> Bool {
        guard isVisible else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            list.moveSelection(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            list.moveSelection(by: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            guard let item = list.selectedItem else { return false }
            onPick?(item)
            dismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return event }
                if let item = self.list.item(at: event) {
                    if event.type == .leftMouseDown {
                        self.onPick?(item)
                        self.dismiss()
                        return nil
                    }
                    return event
                }
                if self.anchorContains(event) {
                    return event
                }
                self.dismiss()
                return event
            }
        }
    }

    private func anchorContains(_ event: NSEvent) -> Bool {
        guard let anchor, let window = event.window, window === anchor.window else { return false }
        let local = anchor.convert(event.locationInWindow, from: nil)
        return anchor.bounds.contains(local)
    }

    private func position(anchor: NSView, host: NSView) {
        let anchorRect = anchor.convert(anchor.bounds, to: host)
        let height = list.preferredHeight
        var frame = NSRect(x: anchorRect.minX, y: anchorRect.minY - height - 4, width: anchorRect.width, height: height)
        if frame.minY < 8 {
            frame.origin.y = anchorRect.maxY + 4
        }
        let limit = host.bounds.insetBy(dx: 8, dy: 8)
        if frame.maxX > limit.maxX {
            frame.origin.x = max(limit.minX, limit.maxX - frame.width)
        }
        if frame.minX < limit.minX {
            frame.origin.x = limit.minX
        }
        list.frame = frame
    }
}

@MainActor
final class SuggestionListView: NSView {
    private var items: [HistorySuggestion] = []
    private var selectedIndex: Int?
    private let rowHeight: CGFloat = 36

    var selectedItem: HistorySuggestion? {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    var preferredHeight: CGFloat {
        CGFloat(max(items.count, 1)) * rowHeight
    }

    func apply(_ items: [HistorySuggestion]) {
        let previous = selectedItem?.url
        self.items = items
        if let previous, let index = items.firstIndex(where: { $0.url == previous }) {
            selectedIndex = index
        } else {
            selectedIndex = nil
        }
        needsDisplay = true
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let next: Int
        if let selectedIndex {
            next = min(max(selectedIndex + delta, 0), items.count - 1)
        } else {
            next = delta >= 0 ? 0 : items.count - 1
        }
        selectedIndex = next
        needsDisplay = true
    }

    func item(at event: NSEvent) -> HistorySuggestion? {
        guard let window = event.window, window === self.window else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return nil }
        let index = rowIndex(at: local)
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: MonoMetrics.urlRadius, yRadius: MonoMetrics.urlRadius)
        Theme.field.setFill()
        background.fill()
        Theme.fieldLine.setStroke()
        background.lineWidth = 1
        background.stroke()

        for (index, item) in items.enumerated() {
            let row = rowRect(index)
            if index == selectedIndex {
                Theme.accent.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
            }
            let title = item.title.isEmpty ? item.url : item.title
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.font(size: 13),
                .foregroundColor: Theme.text
            ]
            let urlAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.font(size: 11),
                .foregroundColor: Theme.mute
            ]
            let titleRect = NSRect(x: row.minX + 12, y: row.midY + 1, width: row.width - 24, height: 16)
            let urlRect = NSRect(x: row.minX + 12, y: row.midY - 15, width: row.width - 24, height: 14)
            draw(title, in: titleRect, attributes: titleAttrs)
            draw(item.url, in: urlRect, attributes: urlAttrs)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func rowRect(_ index: Int) -> NSRect {
        // AppKit views are not flipped: row 0 is the top of the list.
        let y = bounds.height - CGFloat(index + 1) * rowHeight
        return NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
    }

    private func rowIndex(at point: NSPoint) -> Int {
        guard rowHeight > 0 else { return 0 }
        let fromTop = bounds.height - point.y
        return Int(fromTop / rowHeight)
    }

    private func draw(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let string = NSAttributedString(string: text, attributes: attributes)
        let measured = string.boundingRect(with: NSSize(width: rect.width, height: rect.height), options: [.usesLineFragmentOrigin])
        var drawing = rect
        if measured.width > rect.width {
            let ns = text as NSString
            var count = text.count
            while count > 1 {
                let candidate = ns.substring(to: count) + "…"
                let width = (candidate as NSString).size(withAttributes: attributes).width
                if width <= rect.width { 
                    NSAttributedString(string: candidate, attributes: attributes).draw(in: drawing)
                    return
                }
                count -= 1
            }
        }
        drawing.size.height = max(drawing.height, measured.height)
        string.draw(in: drawing)
    }
}
