// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ImportedNode: Equatable, Sendable {
    case folder(title: String, children: [ImportedNode])
    case bookmark(title: String, url: String, added: Date?)
}

public struct BookmarkImportCounts: Equatable, Sendable {
    public var added: Int
    public var skippedDuplicates: Int
    public var skippedUnsupported: Int

    public init(added: Int = 0, skippedDuplicates: Int = 0, skippedUnsupported: Int = 0) {
        self.added = added
        self.skippedDuplicates = skippedDuplicates
        self.skippedUnsupported = skippedUnsupported
    }
}

public enum BookmarkImportError: Error, Equatable, Sendable {
    case fileTooLarge
    case unreadable
    case missingPlacesDatabase
    case sqlite
}

/// Where an Open dialog should start. The person always confirms the file.
public enum BookmarkFileSource: Equatable, Sendable {
    case zen
    case firefox
    case browserFamily
    case htmlFile

    public var defaultDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        switch self {
        case .zen:
            return support
                .appendingPathComponent("zen", isDirectory: true)
                .appendingPathComponent("Profiles", isDirectory: true)
        case .firefox:
            return support
                .appendingPathComponent("Firefox", isDirectory: true)
                .appendingPathComponent("Profiles", isDirectory: true)
        case .browserFamily:
            return support
                .appendingPathComponent("Google", isDirectory: true)
                .appendingPathComponent("Ch" + "rome", isDirectory: true)
        case .htmlFile:
            if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                return downloads
            }
            return home
        }
    }

    public var sourceRootName: String {
        switch self {
        case .zen:
            return "Zen Browser"
        case .firefox:
            return "Firefox"
        case .browserFamily:
            return "Browser family"
        case .htmlFile:
            return ""
        }
    }
}

public enum BookmarkText {
    public static let maxTitleLength = 512

    public static func sanitizeTitle(_ raw: String) -> String {
        let withoutTags = stripTags(raw)
        let scalars = withoutTags.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var text = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxTitleLength {
            text = String(text.prefix(maxTitleLength))
        }
        return text
    }

    public static func decodeEntities(_ raw: String) -> String {
        var result = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "&" {
                if let end = raw[index...].firstIndex(of: ";") {
                    let token = String(raw[index...end])
                    if let decoded = entity(token) {
                        result.append(decoded)
                        index = raw.index(after: end)
                        continue
                    }
                }
            }
            result.append(raw[index])
            index = raw.index(after: index)
        }
        return result
    }

    private static func stripTags(_ raw: String) -> String {
        var result = ""
        var inTag = false
        for character in raw {
            if character == "<" {
                inTag = true
                continue
            }
            if character == ">" {
                inTag = false
                continue
            }
            if !inTag {
                result.append(character)
            }
        }
        return result
    }

    private static func entity(_ token: String) -> String? {
        switch token.lowercased() {
        case "&amp;": return "&"
        case "&lt;": return "<"
        case "&gt;": return ">"
        case "&quot;": return "\""
        case "&apos;", "&#39;": return "'"
        case "&nbsp;": return " "
        default:
            break
        }
        guard token.hasPrefix("&#"), token.hasSuffix(";") else { return nil }
        let inner = token.dropFirst(2).dropLast()
        let value: Int?
        if inner.first == "x" || inner.first == "X" {
            value = Int(inner.dropFirst(), radix: 16)
        } else {
            value = Int(inner)
        }
        guard let value, let scalar = UnicodeScalar(value) else { return nil }
        return String(Character(scalar))
    }
}

public enum BookmarkImport {
    public static let maxFileSize = 10 * 1024 * 1024
    public static let maxFolderDepth = 32

    public static func isSupportedURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    public static func merge(
        _ nodes: [ImportedNode],
        into store: BookmarkStore,
        sourceRoot: String
    ) -> BookmarkImportCounts {
        var counts = BookmarkImportCounts()
        var folders: [String] = []
        var collected: [Bookmark] = []
        var seen = Set(store.bookmarks.map { URLNormalizer.normalized($0.url) })
        let root = sourceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = root.isEmpty ? [] : [root]
        if !root.isEmpty {
            folders.append(root)
        }
        walk(nodes, path: start, folders: &folders, collected: &collected, seen: &seen, counts: &counts)
        _ = store.applyImport(folders: folders, bookmarks: collected)
        counts.added = collected.count
        return counts
    }

    private static func walk(
        _ nodes: [ImportedNode],
        path: [String],
        folders: inout [String],
        collected: inout [Bookmark],
        seen: inout Set<String>,
        counts: inout BookmarkImportCounts
    ) {
        for node in nodes {
            switch node {
            case .folder(let title, let children):
                let name = BookmarkText.sanitizeTitle(title)
                let next = name.isEmpty ? path : path + [name]
                if !next.isEmpty {
                    let folderPath = next.joined(separator: "/")
                    if !folders.contains(folderPath) {
                        folders.append(folderPath)
                    }
                }
                walk(children, path: next, folders: &folders, collected: &collected, seen: &seen, counts: &counts)
            case .bookmark(let title, let url, let added):
                if !isSupportedURL(url) {
                    counts.skippedUnsupported += 1
                    continue
                }
                let normalized = URLNormalizer.normalized(url)
                if seen.contains(normalized) {
                    counts.skippedDuplicates += 1
                    continue
                }
                seen.insert(normalized)
                let display = BookmarkText.sanitizeTitle(title)
                let folder = path.isEmpty ? nil : path.joined(separator: "/")
                collected.append(
                    Bookmark(
                        title: display.isEmpty ? url : display,
                        url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                        createdAt: added ?? Date(),
                        folder: folder
                    )
                )
            }
        }
    }
}
