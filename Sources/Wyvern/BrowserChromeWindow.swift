// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit

/// Browser window whose transparent title bar must not steal a tab gesture.
///
/// The 38-point strip sits under `fullSizeContentView`. AppKit still treats that
/// band as a title-bar drag region. If a tab's `mouseDown` returns without a
/// tracking loop, a later `mouseDragged` moves this window with the pointer.
final class BrowserChromeWindow: NSWindow {
    /// True from tab mouse-down until mouse-up (including Escape).
    private(set) var suppressChromeWindowDrag = false
    private var movableBeforeTabGesture = true

    func beginSuppressingWindowDrag() {
        if !suppressChromeWindowDrag {
            movableBeforeTabGesture = isMovable
        }
        suppressChromeWindowDrag = true
        isMovable = false
    }

    func endSuppressingWindowDrag() {
        guard suppressChromeWindowDrag else { return }
        suppressChromeWindowDrag = false
        isMovable = movableBeforeTabGesture
    }

    /// Empty chrome calls this. A live tab gesture must not start a window-move loop.
    override func performDrag(with event: NSEvent) {
        guard TabDragPolicy.allowsExplicitWindowDrag(tabGestureActive: suppressChromeWindowDrag) else {
            return
        }
        super.performDrag(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, hitIsTabControl(event) {
            beginSuppressingWindowDrag()
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            endSuppressingWindowDrag()
        }
    }

    private func hitIsTabControl(_ event: NSEvent) -> Bool {
        guard let content = contentView else { return false }
        let inSuperview: NSPoint
        if let host = content.superview {
            inSuperview = host.convert(event.locationInWindow, from: nil)
        } else {
            inSuperview = event.locationInWindow
        }
        var node = content.hitTest(inSuperview)
        while let view = node {
            let name = NSStringFromClass(type(of: view))
            if name.hasSuffix("TabItemView") || name.hasSuffix("TabCloseButton") {
                return true
            }
            node = view.superview
        }
        return false
    }
}
