// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "\(AppInfo.fallbackBundleIdentifier).tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testFirstLaunchDefaults() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings, .firstLaunch)
        XCTAssertEqual(store.settings.appearance, .dark)
        XCTAssertEqual(store.settings.colorTheme, .standard)
        XCTAssertEqual(store.settings.searchEngineID, SearchEngine.duckDuckGo.id)
        XCTAssertFalse(store.settings.didChooseSearchEngine)
        XCTAssertTrue(store.settings.netHealthEnabled)
        XCTAssertFalse(store.settings.hideWebTabs)
        XCTAssertFalse(store.settings.hideTerminalTabs)
        XCTAssertTrue(store.settings.terminalOpenInNewTab)
        XCTAssertEqual(store.settings.terminalShell, "")
        XCTAssertEqual(store.settings.terminalFontSize, 13)
        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertFalse(store.settings.tourSeen)
        XCTAssertFalse(store.settings.developerToolsEnabled)
    }

    func testTerminalDefaultsRoundTripAndFontBounds() {
        let store = SettingsStore(defaults: defaults)
        store.update { settings in
            settings.terminalOpenInNewTab = false
            settings.terminalShell = "/bin/zsh"
            settings.terminalFontSize = 15
        }
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.settings.terminalOpenInNewTab)
        XCTAssertEqual(reloaded.settings.terminalShell, "/bin/zsh")
        XCTAssertEqual(reloaded.settings.terminalFontSize, 15)
        store.update { $0.terminalFontSize = 4 }
        XCTAssertEqual(store.settings.terminalFontSize, 13)
        store.update { $0.terminalFontSize = 30 }
        XCTAssertEqual(store.settings.terminalFontSize, 13)
    }

    func testRoundTripAndCorruptPayloadFallsBack() {
        let store = SettingsStore(defaults: defaults)
        store.update { settings in
            settings.appearance = .dark
            settings.searchEngineID = SearchEngine.kagi.id
            settings.didChooseSearchEngine = true
        }
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings.appearance, .dark)
        XCTAssertEqual(reloaded.settings.searchEngineID, SearchEngine.kagi.id)
        XCTAssertTrue(reloaded.settings.didChooseSearchEngine)
        XCTAssertEqual(reloaded.settings.resolvedSearchEngine().id, SearchEngine.kagi.id)

        defaults.set(Data("nope".utf8), forKey: AppInfo.settingsDefaultsKey)
        let recovered = SettingsStore(defaults: defaults)
        XCTAssertEqual(recovered.settings, .firstLaunch)
    }

    func testHideBothTabsNormalizesToKeepWeb() {
        let store = SettingsStore(defaults: defaults)
        store.update { settings in
            settings.hideTerminalTabs = true
            settings.hideWebTabs = true
        }
        XCTAssertTrue(store.settings.hideTerminalTabs)
        XCTAssertFalse(store.settings.hideWebTabs)
        XCTAssertTrue(store.settings.tabVisibility.allows(.web))
        XCTAssertFalse(store.settings.tabVisibility.allows(.terminal))
    }

    func testAppearanceMigration() throws {
        XCTAssertEqual(AppSettings.migrateAppearance("system"), .system)
        XCTAssertEqual(AppSettings.migrateAppearance("dark"), .dark)
        XCTAssertEqual(AppSettings.migrateAppearance("light"), .light)
        XCTAssertEqual(AppSettings.migrateAppearance(nil), .dark)
        XCTAssertEqual(AppSettings.migrateAppearance("SYSTEM"), .system)
        XCTAssertEqual(AppSettings.migrateAppearance(""), .dark)
        XCTAssertEqual(AppSettings.migrateAppearance("nope"), .dark)
        XCTAssertEqual(AppSettings.migrateColorTheme(nil), .standard)
        XCTAssertEqual(AppSettings.migrateColorTheme("hermes"), .hermes)
        XCTAssertEqual(AppSettings.migrateColorTheme("GRAPHITE"), .graphite)
        XCTAssertEqual(AppSettings.migrateColorTheme("paper"), .paper)
        XCTAssertEqual(AppSettings.migrateColorTheme("nord"), .nord)
        XCTAssertEqual(AppSettings.migrateColorTheme("standard"), .standard)
        XCTAssertEqual(AppSettings.migrateColorTheme("nope"), .standard)

        func decode(_ json: String) throws -> AppSettings {
            try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"appearance":"system"}"#).appearance, .system)
        XCTAssertEqual(try decode(#"{"appearance":"dark"}"#).appearance, .dark)
        XCTAssertEqual(try decode(#"{"appearance":"light"}"#).appearance, .light)
        XCTAssertEqual(try decode(#"{}"#).appearance, .dark)
        XCTAssertEqual(try decode(#"{}"#).colorTheme, .standard)
        XCTAssertEqual(try decode(#"{"colorTheme":"hermes"}"#).colorTheme, .hermes)
        XCTAssertEqual(try decode(#"{"colorTheme":"nope"}"#).colorTheme, .standard)
        XCTAssertEqual(try decode(#"{"appearance":"system"}"#).schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(try decode(#"{}"#).netHealthEnabled)
        XCTAssertTrue(try decode(#"{}"#).hardwareAcceleration)
        XCTAssertFalse(try decode(#"{"hardwareAcceleration":false}"#).hardwareAcceleration)
        XCTAssertTrue(try decode(#"{}"#).terminalOpenInNewTab)
        XCTAssertEqual(try decode(#"{}"#).terminalShell, "")
        XCTAssertEqual(try decode(#"{}"#).terminalFontSize, 13)
        XCTAssertEqual(try decode(#"{}"#).cookiePolicy, .allowAll)
        XCTAssertEqual(try decode(#"{}"#).startupPage, .newTab)
        XCTAssertEqual(try decode(#"{}"#).startupURL, "")
        XCTAssertEqual(try decode(#"{}"#).downloadsDirectoryPath, "")
        XCTAssertFalse(try decode(#"{}"#).askWhereToSaveDownloads)
        XCTAssertFalse(try decode(#"{}"#).openAfterDownload)
        XCTAssertEqual(try decode(#"{}"#).defaultFontSize, 16)
        XCTAssertEqual(try decode(#"{}"#).defaultZoomPercent, 100)
        XCTAssertEqual(try decode(#"{"terminalFontSize":15}"#).terminalFontSize, 15)
        XCTAssertEqual(try decode(#"{"terminalFontSize":4}"#).terminalFontSize, 13)
        XCTAssertEqual(try decode(#"{"terminalFontSize":30}"#).terminalFontSize, 13)
        XCTAssertEqual(try decode(#"{}"#).schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertFalse(try decode(#"{}"#).tourSeen)
        XCTAssertFalse(try decode(#"{}"#).developerToolsEnabled)
        XCTAssertFalse(try decode(#"{"developerToolsEnabled":false}"#).developerToolsEnabled)
        XCTAssertTrue(try decode(#"{"developerToolsEnabled":true}"#).developerToolsEnabled)
        XCTAssertFalse(try decode(#"{"tourSeen":false}"#).tourSeen)
        XCTAssertTrue(try decode(#"{"tourSeen":true}"#).tourSeen)
    }

    func testTourSeenDefaultsFalseAndPersists() throws {
        XCTAssertFalse(AppSettings.firstLaunch.tourSeen)
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data(#"{}"#.utf8))
        XCTAssertFalse(missing.tourSeen)

        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.settings.tourSeen)
        store.update { $0.tourSeen = true }
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.settings.tourSeen)

        let withoutKey = #"{"appearance":"light","didChooseSearchEngine":true}"#
        defaults.set(Data(withoutKey.utf8), forKey: AppInfo.settingsDefaultsKey)
        let decoded = SettingsStore(defaults: defaults)
        XCTAssertFalse(decoded.settings.tourSeen)
        XCTAssertEqual(decoded.settings.appearance, .light)
        XCTAssertTrue(decoded.settings.didChooseSearchEngine)

        decoded.update { $0.tourSeen = false }
        let encoded = try JSONEncoder().encode(decoded.settings)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("\"tourSeen\":false"))
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertFalse(roundTrip.tourSeen)
        decoded.update { $0.tourSeen = true }
        let saved = SettingsStore(defaults: defaults)
        XCTAssertTrue(saved.settings.tourSeen)
    }

    func testColorThemePersistsAndUnknownFallsBack() throws {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings.colorTheme, .standard)
        store.update { $0.colorTheme = .hermes }
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings.colorTheme, .hermes)
        XCTAssertEqual(reloaded.settings.appearance, .dark)
        reloaded.update { settings in
            settings.appearance = .light
            settings.colorTheme = .paper
        }
        let again = SettingsStore(defaults: defaults)
        XCTAssertEqual(again.settings.appearance, .light)
        XCTAssertEqual(again.settings.colorTheme, .paper)
        let encoded = try JSONEncoder().encode(again.settings)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"colorTheme\":\"paper\""))
    }

    func testHardwareAccelerationDefaultsOnAndPersists() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.settings.hardwareAcceleration)
        store.update { $0.hardwareAcceleration = false }
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.settings.hardwareAcceleration)
    }

    func testDeveloperToolsDefaultsOffAndPersists() throws {
        XCTAssertFalse(AppSettings.firstLaunch.developerToolsEnabled)
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.settings.developerToolsEnabled)
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data(#"{}"#.utf8))
        XCTAssertFalse(missing.developerToolsEnabled)

        store.update { $0.developerToolsEnabled = true }
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.settings.developerToolsEnabled)
        let on = try JSONEncoder().encode(reloaded.settings)
        XCTAssertTrue(String(decoding: on, as: UTF8.self).contains("\"developerToolsEnabled\":true"))

        reloaded.update { $0.developerToolsEnabled = false }
        let again = SettingsStore(defaults: defaults)
        XCTAssertFalse(again.settings.developerToolsEnabled)
        let off = try JSONEncoder().encode(again.settings)
        XCTAssertTrue(String(decoding: off, as: UTF8.self).contains("\"developerToolsEnabled\":false"))
    }

    func testSavedDocumentWithRemovedKeyStillLoads() throws {
        let removed = ["launch", "er"].joined()
        let json = "{\"appearance\":\"light\",\"\(removed)\":true,\"didChooseSearchEngine\":true}"
        defaults.set(Data(json.utf8), forKey: AppInfo.settingsDefaultsKey)
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings.appearance, .light)
        XCTAssertTrue(store.settings.didChooseSearchEngine)
        XCTAssertEqual(store.settings.searchEngineID, SearchEngine.duckDuckGo.id)
        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(store.settings.netHealthEnabled)
        let encoded = try JSONEncoder().encode(store.settings)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains(removed))
    }

    func testBrowserPreferencesDefaultAndPersist() throws {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings.cookiePolicy, .allowAll)
        XCTAssertEqual(store.settings.startupPage, .newTab)
        XCTAssertEqual(store.settings.startupURL, "")
        XCTAssertEqual(store.settings.downloadsDirectoryPath, "")
        XCTAssertFalse(store.settings.askWhereToSaveDownloads)
        XCTAssertFalse(store.settings.openAfterDownload)
        XCTAssertEqual(store.settings.defaultFontSize, 16)
        XCTAssertEqual(store.settings.defaultZoomPercent, 100)
        XCTAssertNil(CookiePolicy.allowAll.contentRuleListJSON)
        XCTAssertFalse(CookiePolicy.allowAll.disallowsHTTPCookies)
        let third = try XCTUnwrap(CookiePolicy.blockThirdParty.contentRuleListJSON)
        XCTAssertTrue(third.contains("\"type\":\"block-cookies\""))
        XCTAssertTrue(third.contains("\"load-type\":[\"third-party\"]"))
        let blocked = try XCTUnwrap(CookiePolicy.blockAll.contentRuleListJSON)
        XCTAssertTrue(blocked.contains("\"type\":\"block-cookies\""))
        XCTAssertFalse(blocked.contains("load-type"))
        XCTAssertTrue(CookiePolicy.blockAll.disallowsHTTPCookies)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(third.utf8)))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(blocked.utf8)))

        store.update { settings in
            settings.cookiePolicy = .blockThirdParty
            settings.startupPage = .customURL
            settings.startupURL = "  https://example.com/start  "
            settings.downloadsDirectoryPath = "/tmp/wyvern-downloads"
            settings.askWhereToSaveDownloads = true
            settings.openAfterDownload = true
            settings.defaultFontSize = 18
            settings.defaultZoomPercent = 150
        }
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings.cookiePolicy, .blockThirdParty)
        XCTAssertEqual(reloaded.settings.startupPage, .customURL)
        XCTAssertEqual(reloaded.settings.startupURL, "https://example.com/start")
        XCTAssertEqual(reloaded.settings.downloadsDirectoryPath, "/tmp/wyvern-downloads")
        XCTAssertTrue(reloaded.settings.askWhereToSaveDownloads)
        XCTAssertTrue(reloaded.settings.openAfterDownload)
        XCTAssertEqual(reloaded.settings.defaultFontSize, 18)
        XCTAssertEqual(reloaded.settings.defaultZoomPercent, 150)
    }

    func testFontZoomAndPolicyNormalize() throws {
        let store = SettingsStore(defaults: defaults)
        store.update { settings in
            settings.defaultFontSize = 4
            settings.defaultZoomPercent = 10
            settings.cookiePolicy = .blockAll
        }
        XCTAssertEqual(store.settings.defaultFontSize, 16)
        XCTAssertEqual(store.settings.defaultZoomPercent, 100)
        store.update { settings in
            settings.defaultFontSize = 30
            settings.defaultZoomPercent = 400
        }
        XCTAssertEqual(store.settings.defaultFontSize, 16)
        XCTAssertEqual(store.settings.defaultZoomPercent, 100)

        func decode(_ json: String) throws -> AppSettings {
            try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"cookiePolicy":"blockAll"}"#).cookiePolicy, .blockAll)
        XCTAssertEqual(try decode(#"{"cookiePolicy":"nope"}"#).cookiePolicy, .allowAll)
        XCTAssertEqual(try decode(#"{"startupPage":"restoreLastSession"}"#).startupPage, .restoreLastSession)
        XCTAssertEqual(try decode(#"{"startupPage":"customURL"}"#).startupPage, .customURL)
        XCTAssertEqual(try decode(#"{"startupPage":"nope"}"#).startupPage, .newTab)
        XCTAssertEqual(try decode(#"{"defaultFontSize":12}"#).defaultFontSize, 12)
        XCTAssertEqual(try decode(#"{"defaultFontSize":24}"#).defaultFontSize, 24)
        XCTAssertEqual(try decode(#"{"defaultFontSize":11}"#).defaultFontSize, 16)
        XCTAssertEqual(try decode(#"{"defaultZoomPercent":50}"#).defaultZoomPercent, 50)
        XCTAssertEqual(try decode(#"{"defaultZoomPercent":200}"#).defaultZoomPercent, 200)
        XCTAssertEqual(try decode(#"{"defaultZoomPercent":49}"#).defaultZoomPercent, 100)
        XCTAssertEqual(AppSettings.migrateCookiePolicy(nil), .allowAll)
        XCTAssertEqual(AppSettings.migrateStartupPage(nil), .newTab)
    }
}
