// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WebKit

/// Writes `developerExtrasEnabled` only when `WKPreferences` implements a setter.
/// `setValue(_:forKey:)` raises `NSUnknownKeyException` for an unknown key, so the
/// key is skipped unless `setDeveloperExtrasEnabled:` or `_setDeveloperExtrasEnabled:` exists.
@MainActor
enum WebInspectorPreferences {
    static let developerExtrasKey = "developerExtrasEnabled"

    static func setDeveloperExtrasEnabled(_ enabled: Bool, on preferences: WKPreferences) {
        guard BrowserTab.canSet(preferences, key: developerExtrasKey) else { return }
        preferences.setValue(enabled, forKey: developerExtrasKey)
    }
}

extension AppDelegate {
    /// Top-level Develop menu. The caller inserts it after View and sets `isHidden` from the setting.
    /// ⌥⌘C starts element selection. ⌥⌘J shows the console. The old ⌥⌘C console mapping is gone.
    func installDevelopMenu(on main: NSMenu) -> NSMenuItem {
        let parent = NSMenuItem(title: "Develop", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Develop")
        submenu.delegate = self
        parent.submenu = submenu
        let inspector = developItem(
            "Show Web Inspector",
            action: #selector(showWebInspector(_:)),
            key: "i"
        )
        showWebInspectorItem = inspector
        submenu.addItem(inspector)
        submenu.addItem(developItem(
            "Start Element Selection",
            action: #selector(startElementSelection(_:)),
            key: "c"
        ))
        submenu.addItem(developItem(
            "Show JavaScript Console",
            action: #selector(showJavaScriptConsole(_:)),
            key: "j"
        ))
        main.addItem(parent)
        return parent
    }

    func refreshDevelopMenuTitles() {
        let hiding = focusedBrowserWindow()?.devToolsMenuTitleIsHide == true
        showWebInspectorItem?.title = hiding ? "Hide Web Inspector" : "Show Web Inspector"
    }

    @objc func showWebInspector(_ sender: Any?) {
        focusedBrowserWindow()?.toggleWebInspector(sender)
    }

    @objc func startElementSelection(_ sender: Any?) {
        focusedBrowserWindow()?.startElementSelection(sender)
    }

    @objc func showJavaScriptConsole(_ sender: Any?) {
        focusedBrowserWindow()?.showJavaScriptConsole(sender)
    }

    private func developItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = [.command, .option]
        entry.target = self
        return entry
    }
}
