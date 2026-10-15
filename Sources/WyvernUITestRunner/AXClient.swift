// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Accessibility and keyboard driver for the built application process.
///
/// Mouse events are posted to `kCGHIDEventTap`, so the window server hit-tests them like a
/// real mouse and fills in the window under the pointer. Events posted with `postToPid` skip
/// that routing; AppKit then has no target window for a click (run 305: every click-driven
/// check failed while every keyboard-only check passed). Because a HID click lands on whatever
/// is on screen, every click first activates the app, raises the target's window, and checks
/// that the app is frontmost and that window is key.
///
/// Keys stay on `postToPid`. They already reach the key window that way, and they can never
/// type into another app if focus is stolen.
final class AXClient {
    let pid: pid_t
    let application: AXUIElement
    /// Global point of the last click or hover, for `UI_DIAG`.
    private(set) var lastPoint: CGPoint?
    /// Identifier of the last element a click, hover, or focus targeted.
    private(set) var lastTarget: String?
    /// Frontmost/key-window failures since the last `takeFrontmostIssue()`.
    private var frontmostIssue: String?

    init(pid: pid_t) {
        self.pid = pid
        application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, 2)
    }

    /// Returns and clears the recorded "not frontmost" reason, if any.
    func takeFrontmostIssue() -> String? {
        let issue = frontmostIssue
        frontmostIssue = nil
        return issue
    }

    /// Activates the app, raises the window that holds `element` (or the focused/main window),
    /// makes it main, and verifies the app is frontmost and that window is key.
    /// Nil means ready. Otherwise the reason starts with "not frontmost" and is also recorded.
    @discardableResult
    func ensureFrontmost(_ element: AXUIElement? = nil) -> String? {
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
            return noteFrontmost("not frontmost: app is not running")
        }
        var window: AXUIElement?
        if let element {
            window = copyElement(element, kAXWindowAttribute as CFString)
        }
        if window == nil {
            window = copyElement(application, kAXFocusedWindowAttribute as CFString)
                ?? copyElement(application, kAXMainWindowAttribute as CFString)
                ?? elements(application, kAXWindowsAttribute as CFString).first
        }
        let standard = window.map { isStandardWindow($0) } ?? false
        for _ in 0..<15 {
            if !isFrontmost() {
                _ = running.activate(options: [.activateIgnoringOtherApps])
                // Cooperative activation (macOS 14+) can ignore activate() from a background
                // CLI; the AX frontmost attribute works for a trusted AX client.
                _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            if let window, standard {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            guard isFrontmost() else { continue }
            // Sheets, popovers, and dialogs are not raised; the app being frontmost is enough.
            guard let window, standard else { return nil }
            if let focused = copyElement(application, kAXFocusedWindowAttribute as CFString), CFEqual(focused, window) {
                return nil
            }
        }
        // Last resort: a real click on the window's top edge activates it like a user would.
        if !isFrontmost(), let window, standard, let origin = point(window, kAXPositionAttribute as CFString),
           let size = size(window, kAXSizeAttribute as CFString), size.width > 40 {
            postRawClick(CGPoint(x: origin.x + size.width / 2, y: origin.y + 4))
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if isFrontmost() { return nil }
        }
        let front = NSWorkspace.shared.frontmostApplication
        let frontText = "frontmost pid \(front?.processIdentifier ?? -1) bundle \(front?.bundleIdentifier ?? "?")"
        if !isFrontmost() {
            return noteFrontmost("not frontmost: \(frontText)")
        }
        let keyTitle = copyElement(application, kAXFocusedWindowAttribute as CFString)
            .flatMap { string($0, kAXTitleAttribute as CFString) } ?? "none"
        let wanted = window.flatMap { string($0, kAXTitleAttribute as CFString) } ?? "?"
        return noteFrontmost("not frontmost: target window \"\(wanted)\" is not key (key \"\(keyTitle)\")")
    }

    /// NSWorkspace's frontmost app can be stale in a CLI process; also ask the AX system-wide
    /// element which app is focused. Either agreeing on our pid counts.
    private func isFrontmost() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        let system = AXUIElementCreateSystemWide()
        guard let focusedApp = copyElement(system, kAXFocusedApplicationAttribute as CFString) else { return false }
        var focusedPid: pid_t = 0
        return AXUIElementGetPid(focusedApp, &focusedPid) == .success && focusedPid == pid
    }

    private func postRawClick(_ global: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: global, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: global, mouseButton: .left) else {
            return
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        up.post(tap: .cghidEventTap)
    }

    private func noteFrontmost(_ reason: String) -> String {
        frontmostIssue = frontmostIssue.map { $0 + "; " + reason } ?? reason
        return reason
    }

    private func isStandardWindow(_ window: AXUIElement) -> Bool {
        string(window, kAXRoleAttribute as CFString) == "AXWindow"
            && string(window, kAXSubroleAttribute as CFString) == "AXStandardWindow"
    }

    func windowTitle() -> String {
        for window in elements(application, kAXWindowsAttribute as CFString) {
            if let title = string(window, kAXTitleAttribute as CFString), !title.isEmpty {
                return title
            }
        }
        return ""
    }

    func value(identifier: String) -> String? {
        guard let element = find(identifier: identifier) else { return nil }
        return string(element, kAXValueAttribute as CFString)
            ?? string(element, kAXDescriptionAttribute as CFString)
    }

    func label(identifier: String) -> String? {
        guard let element = find(identifier: identifier) else { return nil }
        return string(element, kAXDescriptionAttribute as CFString)
            ?? string(element, kAXTitleAttribute as CFString)
            ?? string(element, kAXValueAttribute as CFString)
    }

    func exists(identifier: String) -> Bool {
        find(identifier: identifier) != nil
    }

    func isEnabled(identifier: String) -> Bool {
        guard let element = find(identifier: identifier) else { return false }
        return bool(element, kAXEnabledAttribute as CFString)
    }

    /// One line for a failed launch: raw AX error for the window list, counts, and some identifiers.
    func diagnostics() -> String {
        var value: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        var roleValue: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &roleValue)
        let ids = identifiers()
        return "axWindowsError=\(windowsError.rawValue) axRoleError=\(roleError.rawValue) "
            + "tree=[\(roleTree())] windows=\(windowCount()) title=\"\(windowTitle())\" ids=\(ids.count) first=\(ids.prefix(12).joined(separator: ","))"
    }

    /// Roles three levels below each window, to tell an empty tree from a missing identifier.
    func roleTree() -> String {
        var out: [String] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 4, out.count < 40 else { return }
            let role = string(element, kAXRoleAttribute as CFString) ?? "?"
            let ident = string(element, kAXIdentifierAttribute as CFString) ?? ""
            out.append("\(depth):\(role)" + (ident.isEmpty ? "" : "#\(ident)"))
            for child in childElements(element) { walk(child, depth + 1) }
        }
        for window in elements(application, kAXWindowsAttribute as CFString) { walk(window, 0) }
        return out.joined(separator: " ")
    }

    func windowCount() -> Int {
        elements(application, kAXWindowsAttribute as CFString).count
    }

    func countTabs() -> Int {
        var seen: Set<String> = []
        for identifier in identifiers() {
            guard identifier.hasPrefix("wyvern.tab.") else { continue }
            let rest = identifier.dropFirst("wyvern.tab.".count)
            guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { continue }
            seen.insert(identifier)
        }
        return seen.count
    }

    func isSelected(identifier: String) -> Bool {
        guard let element = find(identifier: identifier) else { return false }
        return bool(element, kAXSelectedAttribute as CFString)
    }

    func clickIdentifier(_ identifier: String) -> Bool {
        lastTarget = identifier
        guard let element = find(identifier: identifier) else { return false }
        return click(element)
    }

    /// Screen rectangle of an element. AX origin is the top-left of the global display, which is
    /// the same space `screencapture -R` and CGEvent mouse positions use.
    func frame(identifier: String) -> CGRect? {
        guard let element = find(identifier: identifier),
              let origin = point(element, kAXPositionAttribute as CFString),
              let size = size(element, kAXSizeAttribute as CFString),
              size.width >= 2, size.height >= 2 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    /// Web content builds its AX tree lazily; poll for it before clicking.
    func hasLabel(_ label: String) -> Bool {
        findLabel(label) != nil
    }

    func clickLabeled(_ label: String) -> Bool {
        lastTarget = "label:\(label)"
        guard let element = findLabel(label) else { return false }
        return click(element)
    }

    func moveToIdentifier(_ identifier: String) -> Bool {
        lastTarget = identifier
        guard let element = find(identifier: identifier) else { return false }
        return moveTo(element)
    }

    /// A real mouse click only. There is no AXPress/AXFocused fallback: a fallback would hide
    /// the click path people use, which is the path under test.
    func focusField(identifier: String) -> Bool {
        lastTarget = identifier
        guard let element = find(identifier: identifier) else { return false }
        return click(element)
    }

    /// One `UI_DIAG` fragment for the element with `identifier` (or a `label:` target).
    func describe(target: String) -> String {
        let element: AXUIElement?
        if target.hasPrefix("label:") {
            element = findLabel(String(target.dropFirst("label:".count)))
        } else {
            element = find(identifier: target)
        }
        guard let element else { return "target \(target) not found" }
        return "target \(target) " + describe(element)
    }

    /// Role, subrole, identifier, screen frame (top-left origin), enabled, focused, actions,
    /// value, selected text and range, and the title of the element's window.
    func describe(_ element: AXUIElement) -> String {
        var parts: [String] = []
        parts.append("role=\(string(element, kAXRoleAttribute as CFString) ?? "-")")
        parts.append("subrole=\(string(element, kAXSubroleAttribute as CFString) ?? "-")")
        parts.append("id=\(string(element, kAXIdentifierAttribute as CFString) ?? "-")")
        if let origin = point(element, kAXPositionAttribute as CFString),
           let size = size(element, kAXSizeAttribute as CFString) {
            parts.append("frame=(\(fmt(origin.x)),\(fmt(origin.y)) \(fmt(size.width))x\(fmt(size.height)))")
        } else {
            parts.append("frame=none")
        }
        parts.append("enabled=\(bool(element, kAXEnabledAttribute as CFString))")
        parts.append("focused=\(bool(element, kAXFocusedAttribute as CFString))")
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let names = names as? [String] {
            parts.append("actions=[\(names.joined(separator: ","))]")
        } else {
            parts.append("actions=[]")
        }
        parts.append("value=\"\(clip(string(element, kAXValueAttribute as CFString) ?? ""))\"")
        parts.append("selected=\"\(clip(string(element, kAXSelectedTextAttribute as CFString) ?? ""))\"")
        if let range = range(element, kAXSelectedTextRangeAttribute as CFString) {
            parts.append("range=\(range.location),\(range.length)")
        } else {
            parts.append("range=none")
        }
        let window = copyElement(element, kAXWindowAttribute as CFString)
        parts.append("window=\"\(window.flatMap { string($0, kAXTitleAttribute as CFString) } ?? "-")\"")
        return parts.joined(separator: " ")
    }

    /// Frontmost app, and the app's focused (key) window title. Another app's window title is
    /// not printed; it can contain account or file names.
    func focusSummary() -> String {
        let front = NSWorkspace.shared.frontmostApplication
        let ours = front?.processIdentifier == pid
        let key = copyElement(application, kAXFocusedWindowAttribute as CFString)
        let keyTitle = key.flatMap { string($0, kAXTitleAttribute as CFString) } ?? "none"
        let focused = copyElement(application, kAXFocusedUIElementAttribute as CFString)
        let focusedText = focused.map { element -> String in
            let role = string(element, kAXRoleAttribute as CFString) ?? "-"
            let ident = string(element, kAXIdentifierAttribute as CFString) ?? "-"
            return "\(role)#\(ident)"
        } ?? "none"
        return "frontmost pid=\(front?.processIdentifier ?? -1) bundle=\(front?.bundleIdentifier ?? "?") ours=\(ours) "
            + "keyWindow=\"\(keyTitle)\" focusedElement=\(focusedText) windows=\(windowCount())"
    }

    /// On-screen, normal-layer window ids of the app, front to back.
    func onScreenWindowIDs() -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else {
            return []
        }
        var ids: [CGWindowID] = []
        for entry in info {
            guard let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid else { continue }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0, let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            ids.append(number)
        }
        return ids
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }

    func selectedText(identifier: String) -> String {
        if let element = find(identifier: identifier),
           let selected = string(element, kAXSelectedTextAttribute as CFString),
           !selected.isEmpty {
            return selected
        }
        if let focused = copyElement(application, kAXFocusedUIElementAttribute as CFString) {
            if let selected = string(focused, kAXSelectedTextAttribute as CFString), !selected.isEmpty {
                return selected
            }
            for child in childElements(focused) {
                if let selected = string(child, kAXSelectedTextAttribute as CFString), !selected.isEmpty {
                    return selected
                }
            }
        }
        return ""
    }

    /// True when the app is showing a sheet, a dialog, or an extra floating window.
    func hasBlockingUI() -> Bool {
        let windows = elements(application, kAXWindowsAttribute as CFString)
        if windows.count > 1 {
            return true
        }
        for window in windows {
            if !elements(window, "AXSheets" as CFString).isEmpty {
                return true
            }
            let subrole = string(window, kAXSubroleAttribute as CFString) ?? ""
            if subrole == "AXDialog" || subrole == "AXSystemDialog" || subrole == "AXFloatingWindow" {
                return true
            }
            if containsRole(window, "AXSheet") || containsRole(window, "AXDialog") {
                return true
            }
        }
        return false
    }

    /// Keys are posted to the pid. A frontmost failure is recorded for the FAIL line, not fatal.
    func typeUnicode(_ text: String) -> Bool {
        ensureFrontmost()
        for character in text {
            var units = Array(String(character).utf16)
            guard !units.isEmpty,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                return false
            }
            units.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
            down.postToPid(pid)
            up.postToPid(pid)
            usleep(12_000)
        }
        return true
    }

    func postKey(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        ensureFrontmost()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    /// 0x37 is the command key. The Carbon key-code header is not imported.
    func postCommandKey(virtualKey: CGKeyCode) -> Bool {
        ensureFrontmost()
        let command = CGKeyCode(0x37)
        guard let modifierDown = CGEvent(keyboardEventSource: nil, virtualKey: command, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false),
              let modifierUp = CGEvent(keyboardEventSource: nil, virtualKey: command, keyDown: false) else {
            return false
        }
        modifierDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        modifierDown.postToPid(pid)
        usleep(12_000)
        keyDown.postToPid(pid)
        usleep(12_000)
        keyUp.postToPid(pid)
        usleep(12_000)
        modifierUp.postToPid(pid)
        return true
    }

    /// A real click: move, then left mouse down and up with click state 1, all posted to
    /// `kCGHIDEventTap` at the centre of the element's AX frame. Fails without posting when the
    /// app is not frontmost, because a HID click would land in whatever window is on top.
    func click(_ element: AXUIElement) -> Bool {
        lastPoint = nil
        guard ensureFrontmost(element) == nil else { return false }
        guard let global = center(element) else { return false }
        lastPoint = global
        let source = CGEventSource(stateID: .hidSystemState)
        guard let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: global,
            mouseButton: .left
        ), let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: global,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: global,
            mouseButton: .left
        ) else {
            return false
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        moved.post(tap: .cghidEventTap)
        settle(0.05)
        down.post(tap: .cghidEventTap)
        settle(0.06)
        up.post(tap: .cghidEventTap)
        // Keys go by pid, a different queue. Let the app finish this click before the next key.
        settle(0.25)
        return true
    }

    /// Hover: a HID mouse-moved event, so tracking areas see the pointer enter.
    func moveTo(_ element: AXUIElement) -> Bool {
        lastPoint = nil
        guard ensureFrontmost(element) == nil else { return false }
        guard let global = center(element) else { return false }
        lastPoint = global
        let source = CGEventSource(stateID: .hidSystemState)
        guard let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: global,
            mouseButton: .left
        ) else {
            return false
        }
        moved.post(tap: .cghidEventTap)
        settle(0.1)
        return true
    }

    /// Left-button drag on `kCGHIDEventTap`: move, mouse-down, dragged steps, mouse-up.
    /// `start` and `end` are global top-left points, the same space as `click(_:)`.
    /// `end.y` greater than `start.y` moves the pointer down the screen.
    /// Each step pauses so the app can deliver `mouseDragged` before the next event;
    /// a burst of dragged events is coalesced and the gesture never leaves the tab.
    @discardableResult
    func drag(
        from start: CGPoint,
        to end: CGPoint,
        steps: Int = 28,
        stepPause: Double = 0.05,
        target: String = "drag"
    ) -> Bool {
        lastPoint = nil
        lastTarget = target
        guard ensureFrontmost() == nil else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: start,
            mouseButton: .left
        ), let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: start,
            mouseButton: .left
        ) else {
            return false
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        moved.post(tap: .cghidEventTap)
        settle(0.12)
        down.post(tap: .cghidEventTap)
        // Let mouseDown arm the tab before the first dragged event.
        settle(0.25)
        let count = max(steps, 1)
        let pause = stepPause > 0 ? stepPause : 0.05
        var step = 1
        while step <= count {
            let t = CGFloat(step) / CGFloat(count)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            guard let dragged = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                return false
            }
            dragged.setIntegerValueField(.mouseEventClickState, value: 1)
            dragged.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            dragged.post(tap: .cghidEventTap)
            settle(pause)
            step += 1
        }
        guard let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left
        ) else {
            return false
        }
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        up.post(tap: .cghidEventTap)
        lastPoint = end
        settle(0.5)
        return true
    }

    func focusedWindowTitle() -> String {
        guard let focused = copyElement(application, kAXFocusedWindowAttribute as CFString) else { return "" }
        return string(focused, kAXTitleAttribute as CFString) ?? ""
    }

    func windowTitles() -> [String] {
        elements(application, kAXWindowsAttribute as CFString).compactMap { element in
            string(element, kAXTitleAttribute as CFString)
        }
    }

    private func settle(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// AX positions are global, top-left origin (y grows down from the top of the main
    /// display). CGEvent mouse positions use that same space, so the centre is not flipped.
    /// Only Cocoa (`NSEvent.mouseLocation`, `NSScreen.frame`) uses a bottom-left origin.
    private func center(_ element: AXUIElement) -> CGPoint? {
        guard let origin = point(element, kAXPositionAttribute as CFString),
              let size = size(element, kAXSizeAttribute as CFString),
              size.width >= 1, size.height >= 1 else {
            return nil
        }
        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    private func findLabel(_ label: String) -> AXUIElement? {
        func matches(_ element: AXUIElement) -> Bool {
            let title = string(element, kAXTitleAttribute as CFString) ?? ""
            let description = string(element, kAXDescriptionAttribute as CFString) ?? ""
            return title == label || description == label
        }
        var found: AXUIElement?
        breadthFirst(budget: 12000) { element in
            if matches(element) { found = element; return false }
            return true
        }
        if found == nil {
            breadthFirst(roots: [application]) { element in
                if matches(element) { found = element; return false }
                return true
            }
        }
        return found
    }

    /// Breadth-first with a visited set, so shallow controls are found even when some deep
    /// subtree is huge or cyclic (run 319 spent the whole depth-first budget in one branch).
    private func find(identifier: String) -> AXUIElement? {
        var found: AXUIElement?
        breadthFirst { element in
            if string(element, kAXIdentifierAttribute as CFString) == identifier {
                found = element
                return false
            }
            return true
        }
        if found == nil {
            // Menus and other non-window elements, as before.
            breadthFirst(roots: [application]) { element in
                if string(element, kAXIdentifierAttribute as CFString) == identifier {
                    found = element
                    return false
                }
                return true
            }
        }
        return found
    }

    private func breadthFirst(roots: [AXUIElement]? = nil, budget: Int = 6000, _ visit: (AXUIElement) -> Bool) {
        var visited = AXVisited()
        var queue = roots ?? elements(application, kAXWindowsAttribute as CFString)
        if queue.isEmpty { queue = [application] }
        var index = 0
        var remaining = budget
        while index < queue.count, remaining > 0 {
            let element = queue[index]
            index += 1
            guard visited.insert(element) else { continue }
            remaining -= 1
            if !visit(element) { return }
            queue.append(contentsOf: childElements(element))
        }
    }

    private func containsRole(_ element: AXUIElement, _ roleName: String) -> Bool {
        var budget = 2000
        var visited = AXVisited()
        func walk(_ node: AXUIElement) -> Bool {
            if budget <= 0 || !visited.insert(node) { return false }
            budget -= 1
            if string(node, kAXRoleAttribute as CFString) == roleName {
                return true
            }
            for child in childElements(node) {
                if walk(child) { return true }
            }
            return false
        }
        return walk(element)
    }

    private func copy(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        guard let value = copy(element, attribute) else { return nil }
        return value as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        guard let value = copy(element, attribute) else { return false }
        if let flag = value as? Bool {
            return flag
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private func identifiers() -> [String] {
        var found: [String] = []
        var seen: Set<String> = []
        breadthFirst { element in
            if let identifier = string(element, kAXIdentifierAttribute as CFString),
               seen.insert(identifier).inserted {
                found.append(identifier)
            }
            return true
        }
        return found
    }

    private func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copy(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Sheets are not `AXChildren`. Popovers are usually their own windows; both are walked.
    private func childElements(_ element: AXUIElement) -> [AXUIElement] {
        var list = elements(element, kAXChildrenAttribute as CFString)
        let sheets = elements(element, "AXSheets" as CFString)
        if !sheets.isEmpty {
            list.append(contentsOf: sheets)
        }
        return list
    }

    private func elements(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        guard let value = copy(element, attribute) else { return [] }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        let count = CFArrayGetCount(array)
        var list: [AXUIElement] = []
        var index: CFIndex = 0
        while index < count {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else {
                index += 1
                continue
            }
            let child = Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
            list.append(child)
            index += 1
        }
        return list
    }

    private func point(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func range(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func size(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Control, option, shift, and command go down before the key and up after it.
    /// Menu shortcuts such as ⌃⌘\ and ⌥⌘I are not delivered by flags on the key event alone.
    func postChord(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        ensureFrontmost()
        let modifiers: [(CGKeyCode, CGEventFlags)] = [
            (0x3B, .maskControl),
            (0x3A, .maskAlternate),
            (0x38, .maskShift),
            (0x37, .maskCommand)
        ]
        let active = modifiers.filter { flags.contains($0.1) }
        for piece in active {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: piece.0, keyDown: true) else { return false }
            down.flags = flags
            down.postToPid(pid)
            usleep(12_000)
        }
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(pid)
        usleep(12_000)
        keyUp.postToPid(pid)
        usleep(12_000)
        for piece in active.reversed() {
            guard let up = CGEvent(keyboardEventSource: nil, virtualKey: piece.0, keyDown: false) else { return false }
            up.flags = []
            up.postToPid(pid)
            usleep(12_000)
        }
        return true
    }

    /// Right-button click on `kCGHIDEventTap`, same routing as `click(_:)`.
    func rightClick(identifier: String) -> Bool {
        lastTarget = identifier
        guard let element = find(identifier: identifier) else { return false }
        lastPoint = nil
        guard ensureFrontmost(element) == nil else { return false }
        guard let global = center(element) else { return false }
        lastPoint = global
        let source = CGEventSource(stateID: .hidSystemState)
        guard let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: global,
            mouseButton: .right
        ), let down = CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseDown,
            mouseCursorPosition: global,
            mouseButton: .right
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseUp,
            mouseCursorPosition: global,
            mouseButton: .right
        ) else {
            return false
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        moved.post(tap: .cghidEventTap)
        settle(0.05)
        down.post(tap: .cghidEventTap)
        settle(0.06)
        up.post(tap: .cghidEventTap)
        settle(0.35)
        return true
    }

    func dismissMenu() {
        _ = postKey(virtualKey: 53, flags: [])
        settle(0.2)
    }

    /// Nil when the leaf was pressed. Otherwise a short reason, including the missing title.
    func pressMenu(path: [String]) -> String? {
        guard let bar = menuBarElement() else { return "menu bar missing" }
        var node = bar
        var current: AXUIElement?
        for (index, component) in path.enumerated() {
            let items = immediateMenuItems(node)
            guard let next = items.first(where: { menuTitleMatches(axTitle($0), component) }) else {
                let walked = path.prefix(index + 1).joined(separator: " > ")
                return "missing \(walked)"
            }
            current = next
            let isLeaf = index == path.count - 1
            if !isLeaf {
                _ = AXUIElementPerformAction(next, kAXPressAction as CFString)
                settle(0.3)
                node = next
            }
        }
        guard let current else { return "missing menu" }
        if isExplicitlyDisabled(current) {
            return "disabled \(path.joined(separator: " > "))"
        }
        let error = AXUIElementPerformAction(current, kAXPressAction as CFString)
        settle(0.35)
        if error != .success {
            return "press failed \(error.rawValue) \(path.joined(separator: " > "))"
        }
        return nil
    }

    /// Titles of the menu at `path`. Intermediate menus are opened so `menuNeedsUpdate` runs.
    func submenuTitles(path: [String]) -> [String]? {
        guard let bar = menuBarElement() else { return nil }
        var node = bar
        for component in path {
            let items = immediateMenuItems(node)
            guard let next = items.first(where: { menuTitleMatches(axTitle($0), component) }) else {
                return nil
            }
            _ = AXUIElementPerformAction(next, kAXPressAction as CFString)
            settle(0.3)
            node = next
        }
        let titles = immediateMenuItems(node).map { axTitle($0) }.filter { !$0.isEmpty }
        dismissMenu()
        return titles.isEmpty ? nil : titles
    }

    /// Press the first enabled menu item whose title equals `title` or contains it.
    func pressMenuItem(matching title: String) -> Bool {
        guard let bar = menuBarElement() else { return false }
        var match: AXUIElement?
        func walk(_ element: AXUIElement) {
            guard match == nil else { return }
            for item in immediateMenuItems(element) {
                let name = axTitle(item)
                if name == title || name.localizedCaseInsensitiveContains(title), !isExplicitlyDisabled(item) {
                    match = item
                    return
                }
                walk(item)
                if match != nil { return }
            }
        }
        walk(bar)
        guard let match else { return false }
        let error = AXUIElementPerformAction(match, kAXPressAction as CFString)
        settle(0.35)
        return error == .success
    }

    /// The first item of File > New Terminal Tab. Empty string means that item was pressed.
    func pressFirstTerminalItem() -> String {
        dismissMenu()
        guard let bar = menuBarElement() else { return "menu bar missing" }
        guard let file = immediateMenuItems(bar).first(where: { axTitle($0) == "File" }) else {
            return "File menu missing"
        }
        _ = AXUIElementPerformAction(file, kAXPressAction as CFString)
        settle(0.35)
        guard let terminal = immediateMenuItems(file).first(where: { axTitle($0) == "New Terminal Tab" }) else {
            dismissMenu()
            return "New Terminal Tab missing"
        }
        _ = AXUIElementPerformAction(terminal, kAXPressAction as CFString)
        var items = immediateMenuItems(terminal).filter { !axTitle($0).isEmpty }
        var polls = 0
        while items.isEmpty && polls < 8 {
            settle(0.25)
            items = immediateMenuItems(terminal).filter { !axTitle($0).isEmpty }
            polls += 1
        }
        guard let first = items.first else {
            dismissMenu()
            return "terminal menu empty"
        }
        let title = axTitle(first)
        if isExplicitlyDisabled(first) {
            dismissMenu()
            return "first terminal item unavailable: \(title)"
        }
        let error = AXUIElementPerformAction(first, kAXPressAction as CFString)
        settle(0.4)
        if error != .success {
            dismissMenu()
            return "press failed \(title)"
        }
        return ""
    }

    /// Right-click `identifier` and press a context-menu item with `title`.
    func pressContextItem(identifier: String, title: String) -> String? {
        guard rightClick(identifier: identifier) else { return "could not right-click \(identifier)" }
        let deadline = Date().addingTimeInterval(2.5)
        var found: AXUIElement?
        while Date() < deadline && found == nil {
            breadthFirst(roots: [application], budget: 8000) { element in
                let role = string(element, kAXRoleAttribute as CFString) ?? ""
                if role == "AXMenuItem",
                   axTitle(element) == title,
                   !isExplicitlyDisabled(element) {
                    found = element
                    return false
                }
                return true
            }
            if found == nil {
                settle(0.2)
            }
        }
        guard let found else {
            dismissMenu()
            return "context item missing \(title)"
        }
        let error = AXUIElementPerformAction(found, kAXPressAction as CFString)
        settle(0.4)
        if error != .success {
            dismissMenu()
            return "context press failed \(title)"
        }
        return nil
    }

    func menuBarHasItem(_ title: String) -> Bool {
        guard let bar = menuBarElement() else { return false }
        return immediateMenuItems(bar).contains { axTitle($0) == title }
    }

    func closeWindow(of identifier: String) -> Bool {
        guard let element = find(identifier: identifier) else { return false }
        let window = copyElement(element, kAXWindowAttribute as CFString) ?? element
        if let button = copyElement(window, kAXCloseButtonAttribute as CFString) {
            let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if error == .success {
                settle(0.3)
                return true
            }
        }
        _ = ensureFrontmost(window)
        return postCommandKey(virtualKey: 13)
    }

    func closeOtherWindows() {
        guard let focused = copyElement(application, kAXFocusedWindowAttribute as CFString) else { return }
        for window in elements(application, kAXWindowsAttribute as CFString) {
            if CFEqual(window, focused) { continue }
            let role = string(window, kAXSubroleAttribute as CFString) ?? ""
            if role != "AXStandardWindow" && role != "AXDialog" && role != "AXSystemDialog" {
                continue
            }
            if let button = copyElement(window, kAXCloseButtonAttribute as CFString) {
                _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
                settle(0.25)
            }
        }
    }

    /// Switch value, when Accessibility exposes it as a string or a number.
    func switchIsOn(identifier: String) -> Bool? {
        guard let element = find(identifier: identifier) else { return nil }
        let text = attributeText(element, kAXValueAttribute as CFString).lowercased()
        if text == "1" || text == "on" || text == "true" { return true }
        if text == "0" || text == "off" || text == "false" { return false }
        return nil
    }

    func focusedSnapshots(matching include: (String) -> Bool) -> [AXSnapshot] {
        guard let root = copyElement(application, kAXFocusedWindowAttribute as CFString) else { return [] }
        return snapshots(in: root, matching: include)
    }

    func snapshots(matchingIdentifier identifier: String) -> [AXSnapshot] {
        var found: [AXSnapshot] = []
        breadthFirst(roots: [application], budget: 8000) { element in
            if string(element, kAXIdentifierAttribute as CFString) == identifier {
                found.append(snapshot(element))
            }
            return true
        }
        return found
    }

    func focusedIdentifiers(matching include: (String) -> Bool) -> [String] {
        focusedSnapshots(matching: include).map(\.identifier)
    }

    /// Value, title, and description of `identifier` and a few descendants.
    /// A badge often stores the count on a child, not on the identified view.
    func subtreeText(identifier: String) -> String {
        guard let root = find(identifier: identifier) else { return "" }
        var parts: [String] = []
        breadthFirst(roots: [root], budget: 40) { element in
            let attributes = [
                kAXValueAttribute as CFString,
                kAXTitleAttribute as CFString,
                kAXDescriptionAttribute as CFString
            ]
            for attribute in attributes {
                let text = attributeText(element, attribute)
                if !text.isEmpty {
                    parts.append(text)
                }
            }
            return true
        }
        return parts.joined(separator: " ")
    }

    func identifiers(matching include: (String) -> Bool) -> [String] {
        var found: [String] = []
        var seen: Set<String> = []
        breadthFirst(roots: [application], budget: 8000) { element in
            if let identifier = string(element, kAXIdentifierAttribute as CFString),
               include(identifier),
               seen.insert(identifier).inserted {
                found.append(identifier)
            }
            return true
        }
        return found
    }

    private func snapshots(in root: AXUIElement, matching include: (String) -> Bool) -> [AXSnapshot] {
        var found: [AXSnapshot] = []
        breadthFirst(roots: [root], budget: 8000) { element in
            if let identifier = string(element, kAXIdentifierAttribute as CFString), include(identifier) {
                found.append(snapshot(element))
            }
            return true
        }
        return found
    }

    private func snapshot(_ element: AXUIElement) -> AXSnapshot {
        AXSnapshot(
            identifier: string(element, kAXIdentifierAttribute as CFString) ?? "",
            title: attributeText(element, kAXTitleAttribute as CFString),
            value: attributeText(element, kAXValueAttribute as CFString),
            label: attributeText(element, kAXDescriptionAttribute as CFString),
            enabled: !isExplicitlyDisabled(element)
        )
    }

    private func attributeText(_ element: AXUIElement, _ attribute: CFString) -> String {
        guard let raw = copy(element, attribute) else { return "" }
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return ""
    }

    private func menuBarElement() -> AXUIElement? {
        copyElement(application, kAXMenuBarAttribute as CFString)
    }

    private func axTitle(_ element: AXUIElement) -> String {
        if let title = string(element, kAXTitleAttribute as CFString), !title.isEmpty {
            return title
        }
        // A menu bar item sometimes leaves its title on the child menu.
        for child in childElements(element) where string(child, kAXRoleAttribute as CFString) == "AXMenu" {
            if let title = string(child, kAXTitleAttribute as CFString), !title.isEmpty {
                return title
            }
        }
        return ""
    }

    /// "View > Split View" and "View > Tiling" are the same command group.
    private func menuTitleMatches(_ actual: String, _ wanted: String) -> Bool {
        if actual == wanted { return true }
        let splitNames = ["Split View", "Tiling"]
        return splitNames.contains(actual) && splitNames.contains(wanted)
    }

    private func isExplicitlyDisabled(_ element: AXUIElement) -> Bool {
        guard copy(element, kAXEnabledAttribute as CFString) != nil else { return false }
        return !bool(element, kAXEnabledAttribute as CFString)
    }

    /// Items directly in this menu. One AXMenu wrapper is flattened; submenus are not.
    private func immediateMenuItems(_ element: AXUIElement) -> [AXUIElement] {
        var items: [AXUIElement] = []
        for child in childElements(element) {
            let role = string(child, kAXRoleAttribute as CFString) ?? ""
            if role == "AXMenuBarItem" || role == "AXMenuItem" {
                items.append(child)
            } else if role == "AXMenu" {
                for grandchild in childElements(child) {
                    let grandchildRole = string(grandchild, kAXRoleAttribute as CFString) ?? ""
                    if grandchildRole == "AXMenuItem" || grandchildRole == "AXMenuBarItem" {
                        items.append(grandchild)
                    }
                }
            }
        }
        return items
    }
}

/// One accessibility element the acceptance checks assert on.
struct AXSnapshot {
    var identifier: String
    var title: String
    var value: String
    var label: String
    var enabled: Bool
}


/// AX trees can contain cycles (a child that lists an ancestor). Without this, a depth-first
/// walk spends its whole budget in the cycle and never reaches later siblings (run 319: only
/// "wyvern.bar" was found while wyvern.address existed).
struct AXVisited {
    private var seen: [CFHashCode: [AXUIElement]] = [:]

    /// False when the element was already visited.
    mutating func insert(_ element: AXUIElement) -> Bool {
        let hash = CFHash(element)
        if let bucket = seen[hash], bucket.contains(where: { CFEqual($0, element) }) {
            return false
        }
        seen[hash, default: []].append(element)
        return true
    }
}
