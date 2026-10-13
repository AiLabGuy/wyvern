// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public extension Notification.Name {
    static let app1BookmarksDidChange = Notification.Name("\(AppInfo.bundleIdentifier).bookmarksDidChange")
}

public struct Bookmark: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    public var createdAt: Date
    /// Nil means the bookmark is ungrouped. Missing keys in older files decode as nil.
    public var folder: String?

    public init(
        id: UUID = UUID(),
        title: String,
        url: String,
        createdAt: Date = Date(),
        folder: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.folder = folder
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case url
        case createdAt
        case folder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(folder, forKey: .folder)
    }
}

public struct BookmarkLibrary: Codable, Equatable, Sendable {
    public var version: Int
    public var folders: [String]
    public var bookmarks: [Bookmark]

    public init(version: Int = 2, folders: [String], bookmarks: [Bookmark]) {
        self.version = version
        self.folders = folders
        self.bookmarks = bookmarks
    }
}

public struct BookmarkGroup: Equatable, Sendable {
    public var name: String
    public var isUnsorted: Bool
    public var bookmarks: [Bookmark]

    public init(name: String, isUnsorted: Bool, bookmarks: [Bookmark]) {
        self.name = name
        self.isUnsorted = isUnsorted
        self.bookmarks = bookmarks
    }
}

/// Identity used to dedupe bookmarks. Scheme and host are lowercased, the fragment is
/// dropped, default ports are removed, and a trailing slash on a non-root path is removed.
public enum URLNormalizer {
    public static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty else {
            return trimmed.lowercased()
        }
        components.scheme = scheme
        if let host = components.host {
            components.host = host.lowercased()
        }
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        components.fragment = nil
        if components.path.isEmpty {
            components.path = "/"
        } else if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? trimmed.lowercased()
    }
}

public enum BookmarkDateFormat {
    public static func addedString(from date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

/// JSON file of bookmarks. The directory is injectable so tests do not touch the home folder.
/// Callers use the store from one thread. The app uses it on the main thread.
/// Version 2 is an object. A version 1 file is a bare array and is rewritten as version 2.
public final class BookmarkStore {
    public static let unsortedName = "Unsorted"

    public private(set) var bookmarks: [Bookmark] = []
    public private(set) var folders: [String] = []
    public let fileURL: URL
    public private(set) var lastErrorDescription: String?

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(AppInfo.bookmarksFileName)
        load()
    }

    public convenience init() {
        self.init(directory: AppLocations.dataDirectory)
    }

    @discardableResult
    public func add(title: String, url: String) -> Bookmark? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }
        let normalized = URLNormalizer.normalized(trimmedURL)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = trimmedTitle.isEmpty ? trimmedURL : trimmedTitle
        if let index = bookmarks.firstIndex(where: { URLNormalizer.normalized($0.url) == normalized }) {
            bookmarks[index].title = displayTitle
            persist()
            postChange()
            return bookmarks[index]
        }
        let bookmark = Bookmark(title: displayTitle, url: trimmedURL, createdAt: Date())
        bookmarks.append(bookmark)
        persist()
        postChange()
        return bookmark
    }

    public func remove(id: UUID) {
        let before = bookmarks.count
        bookmarks.removeAll { $0.id == id }
        guard bookmarks.count != before else { return }
        persist()
        postChange()
    }

    public func removeAll() {
        guard !bookmarks.isEmpty || !folders.isEmpty else {
            persist()
            return
        }
        bookmarks.removeAll()
        folders.removeAll()
        persist()
        postChange()
    }

    public func rename(id: UUID, title: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks[index].title = trimmed.isEmpty ? bookmarks[index].url : trimmed
        persist()
        postChange()
    }

    /// Creates an empty folder. "Unsorted" is reserved for bookmarks that have no folder.
    @discardableResult
    public func addFolder(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.compare(Self.unsortedName, options: .caseInsensitive) == .orderedSame {
            return nil
        }
        if let existing = folders.first(where: { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            return existing
        }
        folders.append(trimmed)
        persist()
        postChange()
        return trimmed
    }

    public func move(id: UUID, toFolder folder: String?) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        if let folder {
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.compare(Self.unsortedName, options: .caseInsensitive) == .orderedSame {
                bookmarks[index].folder = nil
            } else if let existing = folders.first(where: { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
                bookmarks[index].folder = existing
            } else {
                folders.append(trimmed)
                bookmarks[index].folder = trimmed
            }
        } else {
            bookmarks[index].folder = nil
        }
        persist()
        postChange()
    }

    /// Folder creation order, then the Unsorted group. Empty folders stay in the list.
    public func groups() -> [BookmarkGroup] {
        let known = Set(folders)
        var result: [BookmarkGroup] = []
        for folder in folders {
            let items = bookmarks.filter { $0.folder == folder }
            result.append(BookmarkGroup(name: folder, isUnsorted: false, bookmarks: items))
        }
        let loose = bookmarks.filter { bookmark in
            guard let folder = bookmark.folder, !folder.isEmpty, known.contains(folder) else {
                return true
            }
            return false
        }
        result.append(BookmarkGroup(name: Self.unsortedName, isUnsorted: true, bookmarks: loose))
        return result
    }

    public func bookmark(id: UUID) -> Bookmark? {
        bookmarks.first { $0.id == id }
    }

    public func bookmark(matchingURL raw: String) -> Bookmark? {
        let normalized = URLNormalizer.normalized(raw)
        guard !normalized.isEmpty else { return nil }
        return bookmarks.first { URLNormalizer.normalized($0.url) == normalized }
    }

    /// Adds imported bookmarks and folder paths in one write. Duplicates are omitted by the caller.
    @discardableResult
    public func applyImport(folders extraFolders: [String], bookmarks extra: [Bookmark]) -> Int {
        for name in extraFolders {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.compare(Self.unsortedName, options: .caseInsensitive) == .orderedSame {
                continue
            }
            if folders.contains(where: { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
                continue
            }
            folders.append(trimmed)
        }
        var added = 0
        var seen = Set(bookmarks.map { URLNormalizer.normalized($0.url) })
        for item in extra {
            let normalized = URLNormalizer.normalized(item.url)
            if normalized.isEmpty || seen.contains(normalized) {
                continue
            }
            seen.insert(normalized)
            bookmarks.append(item)
            added += 1
        }
        persist()
        postChange()
        return added
    }

    private func load() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            bookmarks = []
            folders = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let library = try? decoder.decode(BookmarkLibrary.self, from: data),
               looksLikeLibrary(data) {
                folders = library.folders
                bookmarks = library.bookmarks
                return
            }
            if let list = try? decoder.decode([Bookmark].self, from: data) {
                folders = []
                bookmarks = list
                persist()
                return
            }
            throw CocoaError(.coderReadCorrupt)
        } catch {
            bookmarks = []
            folders = []
            quarantineCorruptFile(manager: manager, underlying: error)
        }
    }

    /// An array of bookmarks is version 1. A library is a JSON object.
    private func looksLikeLibrary(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [String: Any]
    }

    private func quarantineCorruptFile(manager: FileManager, underlying: Error) {
        let corruptURL = fileURL.appendingPathExtension("corrupt")
        if manager.fileExists(atPath: corruptURL.path) {
            try? manager.removeItem(at: corruptURL)
        }
        do {
            try manager.moveItem(at: fileURL, to: corruptURL)
        } catch {
            try? manager.removeItem(at: fileURL)
            lastErrorDescription = underlying.localizedDescription
        }
    }

    private func persist() {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let library = BookmarkLibrary(version: 2, folders: folders, bookmarks: bookmarks)
            let data = try encoder.encode(library)
            try data.write(to: fileURL, options: [.atomic])
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: .app1BookmarksDidChange, object: self)
    }
}
