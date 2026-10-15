// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Optional process arguments. Absent flags leave the normal launch path unchanged.
public struct LaunchConfiguration: Equatable, Sendable {
    public var dataDirectory: String?
    public var appearance: AppearancePreference?
    public var openTarget: String?
    public var windowWidth: Int?
    public var windowHeight: Int?
    public var printWindowID: Bool
    public var skipEngineChooser: Bool
    public var downloadsDirectory: String?
    public var showDownloads: Bool
    public var bench: Bool
    /// Shows the first-run setup window even when the engine chooser is skipped.
    public var showSetup: Bool

    public init(
        dataDirectory: String? = nil,
        appearance: AppearancePreference? = nil,
        openTarget: String? = nil,
        windowWidth: Int? = nil,
        windowHeight: Int? = nil,
        printWindowID: Bool = false,
        skipEngineChooser: Bool = false,
        downloadsDirectory: String? = nil,
        showDownloads: Bool = false,
        bench: Bool = false,
        showSetup: Bool = false
    ) {
        self.dataDirectory = dataDirectory
        self.appearance = appearance
        self.openTarget = openTarget
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.printWindowID = printWindowID
        self.skipEngineChooser = skipEngineChooser
        self.downloadsDirectory = downloadsDirectory
        self.showDownloads = showDownloads
        self.bench = bench
        self.showSetup = showSetup
    }

    public static let none = LaunchConfiguration()
}

public enum LaunchArguments {
    public static func parse(_ arguments: [String]) -> LaunchConfiguration {
        var config = LaunchConfiguration()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func takeValue() -> String? {
                let next = index + 1
                guard next < arguments.count, !arguments[next].hasPrefix("--") else { return nil }
                index = next
                return arguments[next]
            }
            switch argument {
            case "--wyvern-data-dir":
                config.dataDirectory = takeValue()
            case "--wyvern-appearance":
                if let raw = takeValue() {
                    config.appearance = AppearancePreference(rawValue: raw.lowercased())
                }
            case "--wyvern-open", "--wyvern-open-url":
                config.openTarget = takeValue()
            case "--wyvern-window-size":
                if let raw = takeValue() {
                    let parts = raw.split(separator: "x", omittingEmptySubsequences: false)
                    if parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 {
                        config.windowWidth = width
                        config.windowHeight = height
                    }
                }
            case "--wyvern-print-window-id":
                config.printWindowID = true
            case "--wyvern-skip-engine-chooser":
                config.skipEngineChooser = true
            case "--wyvern-downloads-dir":
                config.downloadsDirectory = takeValue()
            case "--wyvern-show-downloads":
                config.showDownloads = true
            case "--wyvern-bench":
                config.bench = true
            case "--wyvern-show-setup":
                config.showSetup = true
            default:
                break
            }
            index += 1
        }
        return config
    }
}
