// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit

/// Browser window whose transparent title bar must not steal a tab gesture.
///
/// The 38-point strip sits under `fullSizeContentView`. AppKit still treats that
/// band as a title-bar drag region. A tab `mouseDown` that returns without a
/// tracking loop lets a later `mouseDragged` move this window together with the
/// tab snapshot. Hit-testing only `contentView` misses that case when the theme
/// frame or titlebar container is the window's hit view.
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

    /// Empty chrome calls this. A tab hit, or a live tab gesture, must not start a window-move loop.
    override func performDrag(with event: NSEvent) {
        let overTab = tabControl(containing: event) != nil
        guard TabDragPolicy.allowsExplicitWindowDrag(tabGestureActive: suppressChromeWindowDrag || overTab) else {
            return
        }
        super.performDrag(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let tabHit = tabControl(containing: event) {
            // Claim the press before AppKit's titlebar tracking loop can start.
            beginSuppressingWindowDrag()
            deliverTabPointer(event, to: tabHit)
            return
        }
        if suppressChromeWindowDrag, event.type == .leftMouseDragged || event.type == .leftMouseUp {
            isMovable = false
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            endSuppressingWindowDrag()
        }
    }

    /// Walks the content tree in window coordinates. A control drawn above a tab keeps
    /// the click. The titlebar is not inside `contentView`, so a tab under that band is
    /// still found and is not left for AppKit's window-drag loop.
    private func tabControl(containing event: NSEvent) -> NSView? {
        guard let content = contentView else { return nil }
        guard let hit = frontmostDescendant(in: content, windowPoint: event.locationInWindow) else {
            return nil
        }
        var node: NSView? = hit
        while let view = node {
            if view is TabItemView || view is TabCloseButton {
                return view
            }
            if view === content { break }
            node = view.superview
        }
        return nil
    }

    /// Front-most view whose bounds contain the window point, parents before their contents
    /// only when the parent itself contains the point.
    private func frontmostDescendant(in view: NSView, windowPoint: NSPoint) -> NSView? {
        if view.isHidden || view.alphaValue <= 0.01 { return nil }
        let local = view.convert(windowPoint, from: nil)
        guard view.bounds.contains(local) else { return nil }
        for subview in view.subviews.reversed() {
            if let found = frontmostDescendant(in: subview, windowPoint: windowPoint) {
                return found
            }
        }
        return view
    }

    /// Runs the tab or close-button gesture here so `super.sendEvent` cannot start a titlebar drag.
    /// The close button keeps `NSButton`'s own tracking loop. A tab uses its existing
    /// `mouseDragged` / `mouseUp` path, fed from this loop until the button comes up.
    private func deliverTabPointer(_ event: NSEvent, to view: NSView) {
        if !isKeyWindow {
            makeKeyAndOrderFront(nil)
        }
        if view is TabCloseButton {
            view.mouseDown(with: event)
            endSuppressingWindowDrag()
            return
        }
        view.mouseDown(with: event)
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .keyDown]
        while let next = nextEvent(matching: mask, until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .keyDown {
                if next.keyCode == 53 {
                    (windowController as? BrowserWindowController)?.noteTabDragEscape()
                } else {
                    super.sendEvent(next)
                }
                continue
            }
            if next.type == .leftMouseDragged {
                isMovable = false
                view.mouseDragged(with: next)
                continue
            }
            view.mouseUp(with: next)
            endSuppressingWindowDrag()
            return
        }
        if let tab = view as? TabItemView {
            tab.cancelDragSession()
        }
        endSuppressingWindowDrag()
    }
}
