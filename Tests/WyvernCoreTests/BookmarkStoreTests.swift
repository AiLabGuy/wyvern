// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class BookmarkStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-bookmarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testAddRemoveAndRename() throws {
        let store = BookmarkStore(directory: directory)
        let added = try XCTUnwrap(store.add(title: "Example", url: "https://example.com"))
        XCTAssertEqual(store.bookmarks.count, 1)
        store.rename(id: added.id, title: "Renamed")
        XCTAssertEqual(store.bookmark(id: added.id)?.title, "Renamed")
        XCTAssertEqual(store.bookmark(id: added.id)?.url, "https://example.com")
        store.remove(id: added.id)
        XCTAssertTrue(store.bookmarks.isEmpty)
        let reloaded = BookmarkStore(directory: directory)
        XCTAssertTrue(reloaded.bookmarks.isEmpty)
    }

    func testDedupeByNormalizedURLUpdatesTitle() {
        let store = BookmarkStore(directory: directory)
        let first = store.add(title: "One", url: "https://Example.com/a/")
        let second = store.add(title: "Two", url: "https://example.com/a")
        XCTAssertEqual(store.bookmarks.count, 1)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(store.bookmarks.first?.title, "Two")
        XCTAssertEqual(store.bookmarks.first?.url, "https://Example.com/a/")
        XCTAssertNotNil(store.bookmark(matchingURL: "https://example.com:443/a#section"))
    }

    func testDifferentURLsAreNotDeduped() {
        let store = BookmarkStore(directory: directory)
        store.add(title: "A", url: "https://example.com/a")
        store.add(title: "B", url: "https://example.com/b")
        store.add(title: "C", url: "http://example.com/a")
        XCTAssertEqual(store.bookmarks.count, 3)
    }

    func testPersistRoundtrip() throws {
        let store = BookmarkStore(directory: directory)
        let first = try XCTUnwrap(store.add(title: "Docs", url: "https://example.com/docs"))
        let second = try XCTUnwrap(store.add(title: "Root", url: "https://example.org"))
        let file = directory.appendingPathComponent(AppInfo.bookmarksFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let reloaded = BookmarkStore(directory: directory)
        XCTAssertEqual(reloaded.bookmarks.map(\.id), [first.id, second.id])
        XCTAssertEqual(reloaded.bookmarks.map(\.title), ["Docs", "Root"])
        XCTAssertEqual(reloaded.bookmarks.map(\.url), ["https://example.com/docs", "https://example.org"])
        XCTAssertEqual(
            reloaded.bookmarks[0].createdAt.timeIntervalSince1970,
            first.createdAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testCorruptFileIsRenamedAndStoreStartsEmpty() throws {
        let file = directory.appendingPathComponent(AppInfo.bookmarksFileName)
        try Data("{ not json".utf8).write(to: file)
        let store = BookmarkStore(directory: directory)
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let quarantined = file.appendingPathExtension("corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path))
        let body = try Data(contentsOf: quarantined)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{ not json")

        _ = store.add(title: "After", url: "https://example.com")
        let reloaded = BookmarkStore(directory: directory)
        XCTAssertEqual(reloaded.bookmarks.count, 1)
        XCTAssertEqual(reloaded.bookmarks.first?.title, "After")
    }

    func testEmptyURLIsIgnored() {
        let store = BookmarkStore(directory: directory)
        XCTAssertNil(store.add(title: "Nope", url: "   "))
        XCTAssertTrue(store.bookmarks.isEmpty)
    }

    func testEmptyTitleUsesTheURL() {
        let store = BookmarkStore(directory: directory)
        let bookmark = store.add(title: "  ", url: "https://example.com")
        XCTAssertEqual(bookmark?.title, "https://example.com")
    }

    func testNormalizerDropsFragmentAndDefaultPort() {
        XCTAssertEqual(
            URLNormalizer.normalized("HTTPS://Example.COM:443/a/#frag"),
            "https://example.com/a"
        )
        XCTAssertEqual(
            URLNormalizer.normalized("http://example.com:80"),
            "http://example.com/"
        )
    }

    func testVersion1ArrayRewritesAsVersion2() throws {
        let file = directory.appendingPathComponent(AppInfo.bookmarksFileName)
        let id = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        let body = """
        [{"id":"\(id.uuidString)","title":"Docs","url":"https://docs.example.org","createdAt":1791028800}]
        """
        try Data(body.utf8).write(to: file)
        let store = BookmarkStore(directory: directory)
        XCTAssertEqual(store.folders, [])
        XCTAssertEqual(store.bookmarks.count, 1)
        XCTAssertNil(store.bookmarks.first?.folder)
        let raw = try Data(contentsOf: file)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["folders"] as? [String], [])
        let reloaded = BookmarkStore(directory: directory)
        XCTAssertEqual(reloaded.bookmarks.first?.id, id)
        XCTAssertEqual(reloaded.bookmarks.first?.title, "Docs")
    }

    func testFolderOrderGroupingAndMove() {
        let store = BookmarkStore(directory: directory)
        XCTAssertNil(store.addFolder(name: "  "))
        XCTAssertNil(store.addFolder(name: "unsorted"))
        XCTAssertEqual(store.addFolder(name: "Reading"), "Reading")
        XCTAssertEqual(store.addFolder(name: "reading"), "Reading")
        XCTAssertEqual(store.addFolder(name: "Dev"), "Dev")
        let docs = store.add(title: "Docs", url: "https://docs.example.org")
        let loose = store.add(title: "Weather", url: "https://weather.example")
        let docsID = docs!.id
        store.move(id: docsID, toFolder: "dev")
        XCTAssertEqual(store.bookmark(id: docsID)?.folder, "Dev")
        store.move(id: loose!.id, toFolder: "Home")
        XCTAssertEqual(store.folders, ["Reading", "Dev", "Home"])
        let names = store.groups().map(\.name)
        XCTAssertEqual(names, ["Reading", "Dev", "Home", "Unsorted"])
        XCTAssertEqual(store.groups()[0].bookmarks.count, 0)
        XCTAssertEqual(store.groups()[1].bookmarks.map(\.title), ["Docs"])
        XCTAssertEqual(store.groups()[2].bookmarks.map(\.title), ["Weather"])
        XCTAssertTrue(store.groups()[3].isUnsorted)
        XCTAssertTrue(store.groups()[3].bookmarks.isEmpty)
        store.move(id: docsID, toFolder: "Unsorted")
        XCTAssertNil(store.bookmark(id: docsID)?.folder)
        XCTAssertEqual(store.groups().last?.bookmarks.map(\.title), ["Docs"])
        let reloaded = BookmarkStore(directory: directory)
        XCTAssertEqual(reloaded.folders, ["Reading", "Dev", "Home"])
        XCTAssertNil(reloaded.bookmark(id: docsID)?.folder)
    }

    func testRemoveAllClearsFolders() {
        let store = BookmarkStore(directory: directory)
        store.addFolder(name: "Reading")
        store.add(title: "Docs", url: "https://docs.example.org")
        store.removeAll()
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertTrue(store.folders.isEmpty)
        let reloaded = BookmarkStore(directory: directory)
        XCTAssertTrue(reloaded.bookmarks.isEmpty)
        XCTAssertTrue(reloaded.folders.isEmpty)
    }

    func testAddedDateFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_791_028_800)
        XCTAssertEqual(BookmarkDateFormat.addedString(from: date, calendar: calendar), "Oct 3")
    }
}
