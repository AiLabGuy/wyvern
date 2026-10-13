// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Accessibility and keyboard driver. Copied from the UI runner; this target
/// does not depend on App1UITestRunner.
final class AXClient {
    let pid: pid_t
    let application: AXUIElement

    init(pid: pid_t) {
        self.pid = pid
        application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, 2)
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
    }

    func exists(identifier: String) -> Bool {
        find(identifier: identifier) != nil
    }

    func countTabs() -> Int {
        var seen: Set<String> = []
        for identifier in identifiers() {
            guard identifier.hasPrefix("app1.tab.") else { continue }
            let rest = identifier.dropFirst("app1.tab.".count)
            guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { continue }
            seen.insert(identifier)
        }
        return seen.count
    }

    func focusField(identifier: String) -> Bool {
        guard let element = find(identifier: identifier) else { return false }
        if click(element) {
            return true
        }
        let pressed = AXUIElementPerformAction(element, kAXPressAction as CFString)
        let focused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if pressed == .success || focused == .success {
            return true
        }
        return click(element)
    }

    func typeUnicode(_ text: String) -> Bool {
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
        postModifierKey(modifier: CGKeyCode(0x37), flags: .maskCommand, virtualKey: virtualKey)
    }

    /// 0x3B is the control key.
    func postControlKey(virtualKey: CGKeyCode) -> Bool {
        postModifierKey(modifier: CGKeyCode(0x3B), flags: .maskControl, virtualKey: virtualKey)
    }

    private func postModifierKey(modifier: CGKeyCode, flags: CGEventFlags, virtualKey: CGKeyCode) -> Bool {
        guard let modifierDown = CGEvent(keyboardEventSource: nil, virtualKey: modifier, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false),
              let modifierUp = CGEvent(keyboardEventSource: nil, virtualKey: modifier, keyDown: false) else {
            return false
        }
        modifierDown.flags = flags
        keyDown.flags = flags
        keyUp.flags = flags
        modifierDown.postToPid(pid)
        usleep(12_000)
        keyDown.postToPid(pid)
        usleep(12_000)
        keyUp.postToPid(pid)
        usleep(12_000)
        modifierUp.postToPid(pid)
        return true
    }

    func click(_ element: AXUIElement) -> Bool {
        guard let global = center(element) else { return false }
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: global,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: global,
            mouseButton: .left
        ) else {
            return false
        }
        down.postToPid(pid)
        usleep(12_000)
        up.postToPid(pid)
        return true
    }

    private func center(_ element: AXUIElement) -> CGPoint? {
        guard let origin = point(element, kAXPositionAttribute as CFString),
              let size = size(element, kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    /// Breadth-first with a cycle guard: a depth-first walk spent its whole budget inside one
    /// toolbar subtree and never reached app1.address (runs 319-324).
    private func find(identifier: String) -> AXUIElement? {
        for roots in [elements(application, kAXWindowsAttribute as CFString), [application]] {
            var queue = roots
            var seen: [CFHashCode: [AXUIElement]] = [:]
            var index = 0
            var budget = 6000
            while index < queue.count, budget > 0 {
                let element = queue[index]
                index += 1
                let hash = CFHash(element)
                if let bucket = seen[hash], bucket.contains(where: { CFEqual($0, element) }) { continue }
                seen[hash, default: []].append(element)
                budget -= 1
                if string(element, kAXIdentifierAttribute as CFString) == identifier {
                    return element
                }
                queue.append(contentsOf: elements(element, kAXChildrenAttribute as CFString))
            }
        }
        return nil
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

    private func identifiers() -> [String] {
        var found: [String] = []
        var seenIDs: Set<String> = []
        let windows = elements(application, kAXWindowsAttribute as CFString)
        var queue = windows.isEmpty ? [application] : windows
        var seen: [CFHashCode: [AXUIElement]] = [:]
        var index = 0
        var budget = 6000
        while index < queue.count, budget > 0 {
            let element = queue[index]
            index += 1
            let hash = CFHash(element)
            if let bucket = seen[hash], bucket.contains(where: { CFEqual($0, element) }) { continue }
            seen[hash, default: []].append(element)
            budget -= 1
            if let identifier = string(element, kAXIdentifierAttribute as CFString),
               seenIDs.insert(identifier).inserted {
                found.append(identifier)
            }
            queue.append(contentsOf: elements(element, kAXChildrenAttribute as CFString))
        }
        return found
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

    private func size(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}
