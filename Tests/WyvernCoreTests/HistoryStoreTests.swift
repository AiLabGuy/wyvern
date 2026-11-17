// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testYoutubePrefixMatchesHistoryAndBookmarks() throws {
        let store = HistoryStore(directory: directory)
        let youtube = try XCTUnwrap(URL(string: "https://www.youtube.com/"))
        store.record(url: youtube, title: "YouTube", visitedAt: Date(timeIntervalSince1970: 1_700_000_000), countAsVisit: true)
        let bookmark = Bookmark(title: "Example", url: "https://example.com/hello")
        let fromHistory = store.suggestions(matching: "youtube", bookmarks: [])
        XCTAssertEqual(fromHistory.first?.url, "https://www.youtube.com/")
        XCTAssertEqual(fromHistory.first?.title, "YouTube")
        XCTAssertFalse(fromHistory.first?.isBookmark ?? true)

        let onlyBookmark = HistoryMatcher.suggestions(
            query: "youtube",
            visits: [],
            bookmarks: [Bookmark(title: "YouTube", url: "https://www.youtube.com/watch")]
        )
        XCTAssertEqual(onlyBookmark.count, 1)
        XCTAssertTrue(onlyBookmark[0].isBookmark)

        let mixed = store.suggestions(matching: "e", bookmarks: [bookmark])
        XCTAssertTrue(mixed.contains { $0.isBookmark && $0.url == "https://example.com/hello" })
    }

    func testBookmarkRanksAheadOfSameClassHistory() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let visits = [
            HistoryVisit(
                url: "https://youtube.com/feed",
                title: "Feed",
                lastVisited: now,
                visitCount: 40
            )
        ]
        let bookmarks = [Bookmark(title: "YouTube", url: "https://www.youtube.com/")]
        let results = HistoryMatcher.suggestions(query: "youtube", visits: visits, bookmarks: bookmarks, now: now)
        XCTAssertGreaterThanOrEqual(results.count, 2)
        XCTAssertEqual(results[0].url, "https://www.youtube.com/")
        XCTAssertTrue(results[0].isBookmark)
        XCTAssertEqual(results.filter { URLNormalizer.normalized($0.url) == "https://www.youtube.com/" }.count, 1)
    }

    func testSameURLBookmarkAndHistoryMerge() {
        let visit = HistoryVisit(
            url: "https://www.youtube.com/",
            title: "Video site",
            lastVisited: Date(),
            visitCount: 4
        )
        let bookmark = Bookmark(title: "YouTube", url: "https://www.YouTube.com/")
        let results = HistoryMatcher.suggestions(query: "youtube", visits: [visit], bookmarks: [bookmark])
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isBookmark)
        XCTAssertEqual(results[0].title, "YouTube")
        XCTAssertEqual(results[0].visitCount, 4)
    }

    func testEmptyQueryHasNoSuggestions() {
        let visit = HistoryVisit(url: "https://www.youtube.com/", title: "YouTube", lastVisited: Date(), visitCount: 1)
        XCTAssertTrue(HistoryMatcher.suggestions(query: "   ", visits: [visit], bookmarks: []).isEmpty)
    }

    func testSkipsJunkSchemes() throws {
        let store = HistoryStore(directory: directory)
        let junk = [
            "about:blank",
            "data:text/html,hi",
            "javascript:alert(1)",
            "wyvern://newtab",
            "wyvern://bookmarks",
            ""
        ]
        for raw in junk {
            if let url = URL(string: raw), !raw.isEmpty {
                store.record(url: url, title: "Junk")
            }
            XCTAssertFalse(HistoryStore.shouldRecord(urlString: raw), raw)
        }
        XCTAssertTrue(store.visits.isEmpty)
        let forced = HistoryVisit(url: "javascript:alert(1)", title: "alert", lastVisited: Date(), visitCount: 1)
        XCTAssertTrue(HistoryMatcher.suggestions(query: "alert", visits: [forced], bookmarks: []).isEmpty)
        let bookmark = Bookmark(title: "Script", url: "javascript:alert(1)")
        XCTAssertTrue(HistoryMatcher.suggestions(query: "script", visits: [], bookmarks: [bookmark]).isEmpty)
    }

    func testDedupeVisitCountAndTitleRefresh() throws {
        let store = HistoryStore(directory: directory)
        let first = try XCTUnwrap(URL(string: "https://www.YouTube.com/"))
        let second = try XCTUnwrap(URL(string: "https://www.youtube.com/#section"))
        store.record(url: first, title: "New Tab", visitedAt: Date(timeIntervalSince1970: 10))
        store.record(url: second, title: "YouTube", visitedAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(store.visits.count, 1)
        XCTAssertEqual(store.visits[0].visitCount, 2)
        XCTAssertEqual(store.visits[0].title, "YouTube")
        store.record(url: second, title: "YouTube Music", visitedAt: Date(timeIntervalSince1970: 30), countAsVisit: false)
        XCTAssertEqual(store.visits[0].visitCount, 2)
        XCTAssertEqual(store.visits[0].title, "YouTube Music")
        XCTAssertEqual(store.visits[0].lastVisited.timeIntervalSince1970, 20, accuracy: 0.1)
    }

    func testCapacityDropsTheLeastUseful() throws {
        let store = HistoryStore(directory: directory, capacity: 2)
        let a = try XCTUnwrap(URL(string: "https://a.example/"))
        let b = try XCTUnwrap(URL(string: "https://b.example/"))
        let c = try XCTUnwrap(URL(string: "https://c.example/"))
        store.record(url: a, title: "A", visitedAt: Date(timeIntervalSince1970: 1))
        store.record(url: b, title: "B", visitedAt: Date(timeIntervalSince1970: 2))
        store.record(url: c, title: "C", visitedAt: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(store.visits.count, 2)
        XCTAssertFalse(store.visits.contains { $0.url.contains("a.example") })
        let reloaded = HistoryStore(directory: directory, capacity: 2)
        XCTAssertEqual(Set(reloaded.visits.map(\.title)), Set(["B", "C"]))
    }

    func testCorruptFileIsQuarantinedWithoutTouchingBookmarks() throws {
        let history = directory.appendingPathComponent(AppInfo.historyFileName)
        try Data("{ not json".utf8).write(to: history)
        let bookmarks = directory.appendingPathComponent(AppInfo.bookmarksFileName)
        let bookmarkBytes = Data("{\"version\":2,\"folders\":[],\"bookmarks\":[]}".utf8)
        try bookmarkBytes.write(to: bookmarks)

        let store = HistoryStore(directory: directory)
        XCTAssertTrue(store.visits.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.appendingPathExtension("corrupt").path))
        let after = try Data(contentsOf: bookmarks)
        XCTAssertEqual(after, bookmarkBytes)

        let kept = BookmarkStore(directory: directory)
        XCTAssertTrue(kept.bookmarks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookmarks.path))
    }
}
