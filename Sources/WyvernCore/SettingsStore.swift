// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// Cookies for new web views. Third-party and block-all also install a content rule list.
public enum CookiePolicy: String, Codable, CaseIterable, Sendable {
    case allowAll
    case blockThirdParty
    case blockAll

    /// Content rule list JSON, or nil when every cookie is allowed.
    public var contentRuleListJSON: String? {
        switch self {
        case .allowAll:
            return nil
        case .blockThirdParty:
            return """
            [{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}}]
            """
        case .blockAll:
            return """
            [{"trigger":{"url-filter":".*"},"action":{"type":"block-cookies"}}]
            """
        }
    }

    /// Shared cookie store policy. Third-party blocking stays on the content rule so first-party cookies remain.
    public var disallowsHTTPCookies: Bool {
        self == .blockAll
    }
}

/// What a normal launch opens when the previous run exited cleanly.
public enum StartupPage: String, Codable, CaseIterable, Sendable {
    case newTab
    case restoreLastSession
    case customURL
}

public struct AppSettings: Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var appearance: AppearancePreference
    /// Named chrome palette. `standard` uses the existing Light/Dark pair.
    public var colorTheme: ColorTheme
    public var searchEngineID: String
    public var customSearchTemplate: String
    /// False until the person confirms the first-launch engine sheet.
    public var didChooseSearchEngine: Bool
    public var hideTerminalTabs: Bool
    public var hideWebTabs: Bool
    public var netHealthEnabled: Bool
    public var didOfferFirstImport: Bool
    /// Absolute path of a `.app.backup-<ts>` left by the updater; empty when none.
    public var pendingUpdateBackupPath: String
    /// When true, opening a terminal bookmark adds a tab. The bookmark can still say otherwise.
    public var terminalOpenInNewTab: Bool
    /// Absolute shell used when a bookmark leaves shell empty. Empty uses the login shell.
    public var terminalShell: String
    /// Terminal font size in points. Values outside 11...18 become 13.
    public var terminalFontSize: Double
    /// When false, new web views turn off GPU canvas and WebGL. Compositing always uses the GPU.
    public var hardwareAcceleration: Bool
    public var cookiePolicy: CookiePolicy
    public var startupPage: StartupPage
    /// Used when `startupPage` is `.customURL`. Empty falls back to a new tab.
    public var startupURL: String
    /// Absolute downloads folder. Empty uses the system Downloads folder, or the launch override.
    public var downloadsDirectoryPath: String
    public var askWhereToSaveDownloads: Bool
    public var openAfterDownload: Bool
    /// Root font size in points. Values outside 12...24 become 16.
    public var defaultFontSize: Int
    /// Page zoom percent. Values outside 50...200 become 100.
    public var defaultZoomPercent: Int
    /// False until the guided tour has been shown. A missing value stays false.
    public var tourSeen: Bool
    /// When true, the Develop menu is shown and ordinary web pages can be inspected.
    /// A missing value stays false. New tab, bookmarks, settings, and terminal stay closed.
    public var developerToolsEnabled: Bool
    /// http(s) origins that send Command, Option, and Control keys to the page. Missing stays empty.
    public var kvmSites: KVMSiteList

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        appearance: AppearancePreference,
        colorTheme: ColorTheme = .standard,
        searchEngineID: String,
        customSearchTemplate: String,
        didChooseSearchEngine: Bool,
        hideTerminalTabs: Bool = false,
        hideWebTabs: Bool = false,
        netHealthEnabled: Bool = true,
        didOfferFirstImport: Bool = false,
        pendingUpdateBackupPath: String = "",
        terminalOpenInNewTab: Bool = true,
        terminalShell: String = "",
        terminalFontSize: Double = 13,
        hardwareAcceleration: Bool = true,
        cookiePolicy: CookiePolicy = .allowAll,
        startupPage: StartupPage = .newTab,
        startupURL: String = "",
        downloadsDirectoryPath: String = "",
        askWhereToSaveDownloads: Bool = false,
        openAfterDownload: Bool = false,
        defaultFontSize: Int = 16,
        defaultZoomPercent: Int = 100,
        tourSeen: Bool = false,
        developerToolsEnabled: Bool = false,
        kvmSites: KVMSiteList = KVMSiteList()
    ) {
        self.schemaVersion = schemaVersion
        self.appearance = appearance
        self.colorTheme = colorTheme
        self.searchEngineID = searchEngineID
        self.customSearchTemplate = customSearchTemplate
        self.didChooseSearchEngine = didChooseSearchEngine
        self.hideTerminalTabs = hideTerminalTabs
        self.hideWebTabs = hideWebTabs
        self.netHealthEnabled = netHealthEnabled
        self.didOfferFirstImport = didOfferFirstImport
        self.pendingUpdateBackupPath = pendingUpdateBackupPath
        self.terminalOpenInNewTab = terminalOpenInNewTab
        self.terminalShell = terminalShell
        self.hardwareAcceleration = hardwareAcceleration
        self.terminalFontSize = terminalFontSize
        self.cookiePolicy = cookiePolicy
        self.startupPage = startupPage
        self.startupURL = startupURL
        self.downloadsDirectoryPath = downloadsDirectoryPath
        self.askWhereToSaveDownloads = askWhereToSaveDownloads
        self.openAfterDownload = openAfterDownload
        self.defaultFontSize = defaultFontSize
        self.defaultZoomPercent = defaultZoomPercent
        self.tourSeen = tourSeen
        self.developerToolsEnabled = developerToolsEnabled
        self.kvmSites = kvmSites
        normalize()
    }

    public static let firstLaunch = AppSettings(
        appearance: .dark,
        searchEngineID: SearchEngine.duckDuckGo.id,
        customSearchTemplate: "",
        didChooseSearchEngine: false
    )

    public var tabVisibility: TabVisibility {
        TabVisibility(hideWebTabs: hideWebTabs, hideTerminalTabs: hideTerminalTabs)
    }

    /// Hiding every tab kind is invalid. Web tabs stay visible when both flags would be on.
    public mutating func normalize() {
        if hideTerminalTabs && hideWebTabs {
            hideWebTabs = false
        }
        if terminalFontSize < 11 || terminalFontSize > 18 {
            terminalFontSize = 13
        }
        if defaultFontSize < 12 || defaultFontSize > 24 {
            defaultFontSize = 16
        }
        if defaultZoomPercent < 50 || defaultZoomPercent > 200 {
            defaultZoomPercent = 100
        }
        startupURL = startupURL.trimmingCharacters(in: .whitespacesAndNewlines)
        downloadsDirectoryPath = downloadsDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if schemaVersion < AppSettings.currentSchemaVersion {
            schemaVersion = AppSettings.currentSchemaVersion
        }
        kvmSites = KVMSiteList(origins: kvmSites.origins)
    }

    /// Selected engine, or DuckDuckGo when the id is unknown or the custom template is invalid.
    public func resolvedSearchEngine() -> SearchEngine {
        if searchEngineID == SearchEngine.customID {
            return SearchEngine.custom(template: customSearchTemplate) ?? .duckDuckGo
        }
        return SearchEngine.builtIn(id: searchEngineID) ?? .duckDuckGo
    }

    /// Stored `light`, `dark`, and `system` stay as written. Unknown and missing become dark.
    public static func migrateAppearance(_ raw: String?) -> AppearancePreference {
        guard let raw else { return .dark }
        switch raw.lowercased() {
        case AppearancePreference.light.rawValue:
            return .light
        case AppearancePreference.dark.rawValue:
            return .dark
        case AppearancePreference.system.rawValue:
            return .system
        default:
            return .dark
        }
    }

    /// Stored named palettes stay as written. Unknown and missing become the default pair.
    public static func migrateColorTheme(_ raw: String?) -> ColorTheme {
        guard let raw else { return .standard }
        return ColorTheme(rawValue: raw.lowercased()) ?? .standard
    }

    public static func migrateCookiePolicy(_ raw: String?) -> CookiePolicy {
        guard let raw, let policy = CookiePolicy(rawValue: raw) else { return .allowAll }
        return policy
    }

    public static func migrateStartupPage(_ raw: String?) -> StartupPage {
        guard let raw, let page = StartupPage(rawValue: raw) else { return .newTab }
        return page
    }
}

extension AppSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case appearance
        case colorTheme
        case searchEngineID
        case customSearchTemplate
        case didChooseSearchEngine
        case hideTerminalTabs
        case hideWebTabs
        case netHealthEnabled
        case didOfferFirstImport
        case pendingUpdateBackupPath
        case terminalOpenInNewTab
        case terminalShell
        case terminalFontSize
        case hardwareAcceleration
        case cookiePolicy
        case startupPage
        case startupURL
        case downloadsDirectoryPath
        case askWhereToSaveDownloads
        case openAfterDownload
        case defaultFontSize
        case defaultZoomPercent
        case tourSeen
        case developerToolsEnabled
        case kvmSites
    }

    // Keyed decoding ignores unknown keys, so a saved document that still contains a launcher key still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let rawAppearance = try container.decodeIfPresent(String.self, forKey: .appearance)
        appearance = AppSettings.migrateAppearance(rawAppearance)
        let rawTheme = try container.decodeIfPresent(String.self, forKey: .colorTheme)
        colorTheme = AppSettings.migrateColorTheme(rawTheme)
        searchEngineID = try container.decodeIfPresent(String.self, forKey: .searchEngineID)
            ?? SearchEngine.duckDuckGo.id
        customSearchTemplate = try container.decodeIfPresent(String.self, forKey: .customSearchTemplate) ?? ""
        didChooseSearchEngine = try container.decodeIfPresent(Bool.self, forKey: .didChooseSearchEngine) ?? false
        hideTerminalTabs = try container.decodeIfPresent(Bool.self, forKey: .hideTerminalTabs) ?? false
        hideWebTabs = try container.decodeIfPresent(Bool.self, forKey: .hideWebTabs) ?? false
        netHealthEnabled = try container.decodeIfPresent(Bool.self, forKey: .netHealthEnabled) ?? true
        didOfferFirstImport = try container.decodeIfPresent(Bool.self, forKey: .didOfferFirstImport) ?? false
        pendingUpdateBackupPath = try container.decodeIfPresent(String.self, forKey: .pendingUpdateBackupPath) ?? ""
        terminalOpenInNewTab = try container.decodeIfPresent(Bool.self, forKey: .terminalOpenInNewTab) ?? true
        terminalShell = try container.decodeIfPresent(String.self, forKey: .terminalShell) ?? ""
        terminalFontSize = try container.decodeIfPresent(Double.self, forKey: .terminalFontSize) ?? 13
        hardwareAcceleration = try container.decodeIfPresent(Bool.self, forKey: .hardwareAcceleration) ?? true
        let rawCookie = try container.decodeIfPresent(String.self, forKey: .cookiePolicy)
        cookiePolicy = AppSettings.migrateCookiePolicy(rawCookie)
        let rawStartup = try container.decodeIfPresent(String.self, forKey: .startupPage)
        startupPage = AppSettings.migrateStartupPage(rawStartup)
        startupURL = try container.decodeIfPresent(String.self, forKey: .startupURL) ?? ""
        downloadsDirectoryPath = try container.decodeIfPresent(String.self, forKey: .downloadsDirectoryPath) ?? ""
        askWhereToSaveDownloads = try container.decodeIfPresent(Bool.self, forKey: .askWhereToSaveDownloads) ?? false
        openAfterDownload = try container.decodeIfPresent(Bool.self, forKey: .openAfterDownload) ?? false
        defaultFontSize = try container.decodeIfPresent(Int.self, forKey: .defaultFontSize) ?? 16
        defaultZoomPercent = try container.decodeIfPresent(Int.self, forKey: .defaultZoomPercent) ?? 100
        tourSeen = try container.decodeIfPresent(Bool.self, forKey: .tourSeen) ?? false
        developerToolsEnabled = try container.decodeIfPresent(Bool.self, forKey: .developerToolsEnabled) ?? false
        kvmSites = try container.decodeIfPresent(KVMSiteList.self, forKey: .kvmSites) ?? KVMSiteList()
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(colorTheme, forKey: .colorTheme)
        try container.encode(searchEngineID, forKey: .searchEngineID)
        try container.encode(customSearchTemplate, forKey: .customSearchTemplate)
        try container.encode(didChooseSearchEngine, forKey: .didChooseSearchEngine)
        try container.encode(hideTerminalTabs, forKey: .hideTerminalTabs)
        try container.encode(hideWebTabs, forKey: .hideWebTabs)
        try container.encode(netHealthEnabled, forKey: .netHealthEnabled)
        try container.encode(didOfferFirstImport, forKey: .didOfferFirstImport)
        try container.encode(pendingUpdateBackupPath, forKey: .pendingUpdateBackupPath)
        try container.encode(terminalOpenInNewTab, forKey: .terminalOpenInNewTab)
        try container.encode(terminalShell, forKey: .terminalShell)
        try container.encode(terminalFontSize, forKey: .terminalFontSize)
        try container.encode(hardwareAcceleration, forKey: .hardwareAcceleration)
        try container.encode(cookiePolicy, forKey: .cookiePolicy)
        try container.encode(startupPage, forKey: .startupPage)
        try container.encode(startupURL, forKey: .startupURL)
        try container.encode(downloadsDirectoryPath, forKey: .downloadsDirectoryPath)
        try container.encode(askWhereToSaveDownloads, forKey: .askWhereToSaveDownloads)
        try container.encode(openAfterDownload, forKey: .openAfterDownload)
        try container.encode(defaultFontSize, forKey: .defaultFontSize)
        try container.encode(defaultZoomPercent, forKey: .defaultZoomPercent)
        try container.encode(tourSeen, forKey: .tourSeen)
        try container.encode(developerToolsEnabled, forKey: .developerToolsEnabled)
        try container.encode(kvmSites, forKey: .kvmSites)
    }
}

public extension Notification.Name {
    static let wyvernSettingsDidChange = Notification.Name("\(AppInfo.bundleIdentifier).settingsDidChange")
    /// Posted when `developerToolsEnabled` changes. Open web views reapply inspectability.
    /// `userInfo` carries `DeveloperTools.enabledUserInfoKey`.
    static let wyvernDeveloperToolsDidChange = Notification.Name("\(AppInfo.bundleIdentifier).developerToolsDidChange")
}

/// UserDefaults-backed settings. The suite is injectable for tests.
public final class SettingsStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = AppInfo.settingsDefaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public var settings: AppSettings {
        get { load() }
        set {
            var value = newValue
            value.normalize()
            let developerToolsChanged = load().developerToolsEnabled != value.developerToolsEnabled
            save(value)
            NotificationCenter.default.post(name: .wyvernSettingsDidChange, object: self)
            if developerToolsChanged {
                NotificationCenter.default.post(
                    name: .wyvernDeveloperToolsDidChange,
                    object: self,
                    userInfo: DeveloperTools.userInfo(enabled: value.developerToolsEnabled)
                )
            }
        }
    }

    public func update(_ body: (inout AppSettings) -> Void) {
        var value = settings
        body(&value)
        settings = value
    }

    private func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return .firstLaunch
        }
        let decoder = JSONDecoder()
        guard let value = try? decoder.decode(AppSettings.self, from: data) else {
            return .firstLaunch
        }
        return value
    }

    private func save(_ value: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
