// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class DeveloperToolsTests: XCTestCase {
    func testOnlyWebContentIsInspectableAndOnlyWhenEnabled() {
        for surface in WebContentSurface.allCases {
            XCTAssertEqual(
                DeveloperTools.shouldBeInspectable(surface: surface, setting: true),
                surface == .web,
                "\(surface) with the setting on"
            )
            XCTAssertFalse(
                DeveloperTools.shouldBeInspectable(surface: surface, setting: false),
                "\(surface) with the setting off"
            )
        }
    }

    func testDeveloperToolsChangePostsNotification() {
        let suiteName = "\(AppInfo.fallbackBundleIdentifier).tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create a defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        let seen = DeveloperToolsNoteBox()
        let token = NotificationCenter.default.addObserver(
            forName: .wyvernDeveloperToolsDidChange,
            object: store,
            queue: nil
        ) { note in
            guard let enabled = DeveloperTools.enabled(from: note) else {
                XCTFail("developer-tools notification is missing the enabled flag")
                return
            }
            seen.values.append(enabled)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.update { $0.appearance = .light }
        XCTAssertTrue(seen.values.isEmpty)
        store.update { $0.developerToolsEnabled = true }
        store.update { $0.searchEngineID = SearchEngine.kagi.id }
        store.update { $0.developerToolsEnabled = true }
        store.update { $0.developerToolsEnabled = false }
        XCTAssertEqual(seen.values, [true, false])
    }
}

private final class DeveloperToolsNoteBox: @unchecked Sendable {
    var values: [Bool] = []
}
