// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One `[ProfileN]` (or similarly named) section from `profiles.ini`.
public struct INIProfile: Equatable, Sendable {
    public var name: String
    public var path: String
    public var isRelative: Bool
    public var isDefault: Bool
    public var section: String

    public init(name: String, path: String, isRelative: Bool, isDefault: Bool, section: String) {
        self.name = name
        self.path = path
        self.isRelative = isRelative
        self.isDefault = isDefault
        self.section = section
    }
}

/// Parsed `profiles.ini` plus an optional default path from `installs.ini`.
public struct INIProfileFile: Equatable, Sendable {
    public var profiles: [INIProfile]
    /// Path value from `installs.ini` `Default=`, when present. Wins over `Default=1`.
    public var installsDefaultPath: String?

    public init(profiles: [INIProfile], installsDefaultPath: String? = nil) {
        self.profiles = profiles
        self.installsDefaultPath = installsDefaultPath
    }

    public var defaultProfile: INIProfile? {
        if let installsDefaultPath, !installsDefaultPath.isEmpty {
            let needle = installsDefaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = profiles.first(where: { $0.path == needle }) {
                return match
            }
            if let match = profiles.first(where: { $0.path.hasSuffix("/" + needle) || $0.path.hasSuffix(needle) }) {
                return match
            }
        }
        if let marked = profiles.first(where: { $0.isDefault }) {
            return marked
        }
        return profiles.first
    }
}

public enum ProfileINI {
    public static func parse(_ text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]"), line.count >= 2 {
                current = String(line.dropFirst().dropLast())
                if sections[current] == nil {
                    sections[current] = [:]
                }
                continue
            }
            guard !current.isEmpty, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            sections[current, default: [:]][key] = value
        }
        return sections
    }

    public static func parseProfiles(text: String, installsText: String? = nil) -> INIProfileFile {
        let sections = parse(text)
        var profiles: [INIProfile] = []
        for (section, keys) in sections {
            let lower = section.lowercased()
            guard lower.hasPrefix("profile") else { continue }
            let path = keys["Path"] ?? keys["path"] ?? ""
            guard !path.isEmpty else { continue }
            let name = keys["Name"] ?? keys["name"] ?? section
            let relativeRaw = keys["IsRelative"] ?? keys["isRelative"] ?? "1"
            let isRelative = relativeRaw != "0"
            let defaultRaw = keys["Default"] ?? keys["default"] ?? "0"
            let isDefault = defaultRaw == "1"
            profiles.append(
                INIProfile(
                    name: name,
                    path: path,
                    isRelative: isRelative,
                    isDefault: isDefault,
                    section: section
                )
            )
        }
        profiles.sort { $0.section.localizedStandardCompare($1.section) == .orderedAscending }
        let installsDefault = installsText.flatMap { defaultPath(fromInstalls: $0) }
        return INIProfileFile(profiles: profiles, installsDefaultPath: installsDefault)
    }

    /// Standardized and symlink-resolved directory, or nil when it is outside `root`.
    /// Absolute `IsRelative=0` paths and `..` escapes that leave the root are refused.
    public static func resolveDirectory(
        profile: INIProfile,
        root: URL
    ) -> URL? {
        let rootResolved = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate: URL
        if profile.isRelative {
            candidate = root.appendingPathComponent(profile.path, isDirectory: true)
        } else {
            candidate = URL(fileURLWithPath: profile.path, isDirectory: true)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootResolved.path
        let resolvedPath = resolved.path
        if resolvedPath == rootPath { return resolved }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if resolvedPath.hasPrefix(prefix) { return resolved }
        return nil
    }

    public static func defaultPath(fromInstalls text: String) -> String? {
        let sections = parse(text)
        for (section, keys) in sections {
            if section.lowercased().hasPrefix("install") {
                if let value = keys["Default"] ?? keys["default"], !value.isEmpty {
                    return value
                }
            }
        }
        for keys in sections.values {
            if let value = keys["Default"] ?? keys["default"], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
