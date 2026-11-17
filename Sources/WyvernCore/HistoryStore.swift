// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One visited URL. Deduped by `URLNormalizer`. Not a bookmark.
public struct HistoryVisit: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var lastVisited: Date
    public var visitCount: Int

    public init(url: String, title: String, lastVisited: Date, visitCount: Int) {
        self.url = url
        self.title = title
        self.lastVisited = lastVisited
        self.visitCount = visitCount
    }
}

/// One address-bar row, drawn from history, bookmarks, or both.
public struct HistorySuggestion: Equatable, Sendable {
    public var url: String
    public var title: String
    public var isBookmark: Bool
    public var visitCount: Int
    public var lastVisited: Date?

    public init(
        url: String,
        title: String,
        isBookmark: Bool,
        visitCount: Int = 0,
        lastVisited: Date? = nil
    ) {
        self.url = url
        self.title = title
        self.isBookmark = isBookmark
        self.visitCount = visitCount
        self.lastVisited = lastVisited
    }
}

/// Ranks history and bookmarks for the address field. Pure: no disk, no AppKit.
public enum HistoryMatcher {
    public static let suggestionLimit = 8

    public static func suggestions(
        query rawQuery: String,
        visits: [HistoryVisit],
        bookmarks: [Bookmark],
        limit: Int = suggestionLimit,
        now: Date = Date()
    ) -> [HistorySuggestion] {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else { return [] }
        let capped = max(1, limit)

        struct Row {
            var suggestion: HistorySuggestion
            var score: Int
            var visited: Date
        }

        var byURL: [String: Row] = [:]

        for visit in visits {
            guard HistoryStore.shouldRecord(urlString: visit.url) else { continue }
            guard let score = matchScore(query: query, url: visit.url, title: visit.title) else { continue }
            let key = URLNormalizer.normalized(visit.url)
            guard !key.isEmpty else { continue }
            let recency = recencyBonus(lastVisited: visit.lastVisited, now: now)
            let visitsBonus = min(max(visit.visitCount, 0), 20)
            let row = Row(
                suggestion: HistorySuggestion(
                    url: visit.url,
                    title: displayTitle(visit.title, url: visit.url),
                    isBookmark: false,
                    visitCount: visit.visitCount,
                    lastVisited: visit.lastVisited
                ),
                score: score + recency + visitsBonus,
                visited: visit.lastVisited
            )
            if let existing = byURL[key], existing.score >= row.score {
                continue
            }
            byURL[key] = row
        }

        for bookmark in bookmarks {
            guard HistoryStore.shouldRecord(urlString: bookmark.url) else { continue }
            guard let base = matchScore(query: query, url: bookmark.url, title: bookmark.title) else { continue }
            let key = URLNormalizer.normalized(bookmark.url)
            guard !key.isEmpty else { continue }
            // Same-URL history stays one row. The bookmark title and URL win, and the
            // bookmark ranks slightly ahead of a history-only hit in the same match class.
            let boost = 40
            if var existing = byURL[key] {
                existing.suggestion.url = bookmark.url
                existing.suggestion.title = displayTitle(bookmark.title, url: bookmark.url)
                existing.suggestion.isBookmark = true
                existing.score += boost
                byURL[key] = existing
            } else {
                byURL[key] = Row(
                    suggestion: HistorySuggestion(
                        url: bookmark.url,
                        title: displayTitle(bookmark.title, url: bookmark.url),
                        isBookmark: true
                    ),
                    score: base + boost,
                    visited: .distantPast
                )
            }
        }

        return byURL.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.visited != rhs.visited { return lhs.visited > rhs.visited }
            return lhs.suggestion.title.localizedCaseInsensitiveCompare(rhs.suggestion.title) == .orderedAscending
        }
        .prefix(capped)
        .map(\.suggestion)
    }

    /// Lowercased query without a scheme or a leading `www.`. Slashes at the end are dropped
    /// so `youtube` and `youtube/` share a prefix with the host.
    static func normalizedQuery(_ raw: String) -> String {
        var query = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = query.range(of: "://") {
            query = String(query[scheme.upperBound...])
        }
        if query.hasPrefix("www.") {
            query.removeFirst(4)
        }
        while query.hasSuffix("/") {
            query.removeLast()
        }
        return query
    }

    /// Host/URL prefix outranks a title hit. Nil means the candidate does not match.
    static func matchScore(query: String, url: String, title: String) -> Int? {
        guard !query.isEmpty else { return nil }
        let parts = matchParts(url)
        let bareHost = parts.host.hasPrefix("www.") ? String(parts.host.dropFirst(4)) : parts.host
        if bareHost.hasPrefix(query) || parts.host.hasPrefix(query) || labelHasPrefix(parts.host, query: query) {
            return 500
        }
        if parts.display.hasPrefix(query) {
            return 400
        }
        let foldedTitle = title.lowercased()
        if foldedTitle.hasPrefix(query) {
            return 250
        }
        if bareHost.contains(query) || parts.host.contains(query) {
            return 180
        }
        if parts.display.contains(query) {
            return 140
        }
        if foldedTitle.contains(query) {
            return 80
        }
        return nil
    }

    private static func labelHasPrefix(_ host: String, query: String) -> Bool {
        host.split(separator: ".").contains { $0.hasPrefix(query) }
    }

    private static func matchParts(_ raw: String) -> (host: String, display: String) {
        let normalized = URLNormalizer.normalized(raw)
        let source = normalized.isEmpty ? raw : normalized
        guard let components = URLComponents(string: source) else {
            return ("", source.lowercased())
        }
        let host = components.host?.lowercased() ?? ""
        var display = host
        if let port = components.port {
            display += ":\(port)"
        }
        if !components.path.isEmpty, components.path != "/" {
            display += components.path
        }
        if let query = components.query, !query.isEmpty {
            display += "?\(query)"
        }
        return (host, display.lowercased())
    }

    private static func displayTitle(_ title: String, url: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "New Tab" {
            return url
        }
        return trimmed
    }

    /// Up to 15 points. Stays inside one match class so a title hit cannot pass a host prefix.
    private static func recencyBonus(lastVisited: Date, now: Date) -> Int {
        let age = now.timeIntervalSince(lastVisited)
        guard age.isFinite else { return 0 }
        let days = max(0, age / 86_400)
        return max(0, 15 - Int(days))
    }
}

/// `history.json` in the data directory. Does not read or write `bookmarks.json`.
/// Callers use the store from one thread. The app uses it on the main thread.
public final class HistoryStore {
    public static let fileName = AppInfo.historyFileName
    public static let defaultCapacity = 2_000

    public static let shared = HistoryStore()

    public let fileURL: URL
    public let capacity: Int
    public private(set) var visits: [HistoryVisit] = []
    public private(set) var lastErrorDescription: String?

    public init(directory: URL, capacity: Int = HistoryStore.defaultCapacity) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        self.capacity = max(1, capacity)
        load()
    }

    public convenience init() {
        self.init(directory: AppLocations.dataDirectory)
    }

    /// `about:`, `data:`, `javascript:`, internal pages, and empty URLs are not history.
    public static func shouldRecord(_ url: URL) -> Bool {
        shouldRecord(urlString: url.absoluteString)
    }

    public static func shouldRecord(urlString raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        if InternalPage.parse(url) != nil { return false }
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        switch scheme {
        case "about", "data", "javascript", "blob", "wyvern":
            return false
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return false }
            return true
        case "file":
            return true
        default:
            return false
        }
    }

    /// Inserts or updates one visit. `countAsVisit` false refreshes the title only.
    public func record(url: URL, title: String, visitedAt: Date = Date(), countAsVisit: Bool = true) {
        guard Self.shouldRecord(url) else { return }
        let normalized = URLNormalizer.normalized(url.absoluteString)
        guard !normalized.isEmpty else { return }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let weak = cleaned.isEmpty || cleaned == "New Tab"
        if let index = visits.firstIndex(where: { URLNormalizer.normalized($0.url) == normalized }) {
            if countAsVisit {
                visits[index].visitCount += 1
                visits[index].lastVisited = visitedAt
            }
            if !weak {
                visits[index].title = cleaned
            } else if visits[index].title.isEmpty {
                visits[index].title = normalized
            }
        } else {
            visits.append(HistoryVisit(
                url: normalized,
                title: weak ? normalized : cleaned,
                lastVisited: visitedAt,
                visitCount: 1
            ))
        }
        trimToCapacity()
        sortForStorage()
        persist()
    }

    public func suggestions(matching query: String, bookmarks: [Bookmark], limit: Int = HistoryMatcher.suggestionLimit) -> [HistorySuggestion] {
        HistoryMatcher.suggestions(query: query, visits: visits, bookmarks: bookmarks, limit: limit)
    }

    private func trimToCapacity() {
        guard visits.count > capacity else { return }
        visits.sort { usefulness($0) > usefulness($1) }
        visits.removeLast(visits.count - capacity)
    }

    /// Recent visits stay. Each recorded visit is worth up to an hour so a frequently
    /// used older page is not the first one dropped.
    private func usefulness(_ visit: HistoryVisit) -> Double {
        visit.lastVisited.timeIntervalSince1970 + Double(min(max(visit.visitCount, 0), 100)) * 3_600
    }

    private func sortForStorage() {
        visits.sort { lhs, rhs in
            if lhs.lastVisited != rhs.lastVisited { return lhs.lastVisited > rhs.lastVisited }
            return lhs.url < rhs.url
        }
    }

    private struct File: Codable {
        var version: Int
        var visits: [HistoryVisit]
    }

    private func load() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            visits = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let file = try? decoder.decode(File.self, from: data), looksLikeObject(data) {
                visits = file.visits.filter { Self.shouldRecord(urlString: $0.url) }
                trimToCapacity()
                return
            }
            if let list = try? decoder.decode([HistoryVisit].self, from: data) {
                visits = list.filter { Self.shouldRecord(urlString: $0.url) }
                trimToCapacity()
                persist()
                return
            }
            throw CocoaError(.coderReadCorrupt)
        } catch {
            visits = []
            quarantineCorruptFile(manager: manager, underlying: error)
        }
    }

    private func looksLikeObject(_ data: Data) -> Bool {
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
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let file = File(version: 1, visits: visits)
            let data = try encoder.encode(file)
            try PrivateFile.write(data, to: fileURL)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }
}
