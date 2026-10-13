// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import App1Core

final class BookmarkImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app1-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testPlacesTreeShapeAndFolderPaths() throws {
        let url = try fixture("places", ext: "sqlite")
        let imported = try PlacesDatabase.importTree(from: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.tempDirectoryPath))
        let names = folderNames(imported.nodes)
        XCTAssertTrue(names.contains("Toolbar"))
        XCTAssertTrue(names.contains("Dev"))
        XCTAssertTrue(names.contains("Menu"))
        XCTAssertTrue(names.contains("Other"))
        XCTAssertTrue(names.contains("Mobile"))
        XCTAssertFalse(names.contains("tags"))
        XCTAssertFalse(names.contains("Tags"))

        let store = BookmarkStore(directory: directory)
        let counts = BookmarkImport.merge(imported.nodes, into: store, sourceRoot: "Zen Browser")
        XCTAssertGreaterThan(counts.added, 0)
        XCTAssertGreaterThan(counts.skippedUnsupported, 0)
        XCTAssertGreaterThan(counts.skippedDuplicates, 0)
        XCTAssertNotNil(store.bookmark(matchingURL: "https://example.com/dev"))
        XCTAssertEqual(store.bookmark(matchingURL: "https://example.com/dev")?.folder, "Zen Browser/Toolbar/Dev")
        XCTAssertEqual(store.bookmark(matchingURL: "https://example.org/menu")?.folder, "Zen Browser/Menu")
        XCTAssertNil(store.bookmark(matchingURL: "place:type=6&sort=2"))
        XCTAssertNil(store.bookmark(matchingURL: "javascript:alert(1)"))
        XCTAssertNil(store.bookmark(matchingURL: "https://secret-history.example/visited"))
        XCTAssertNil(store.bookmark(matchingURL: "data:text/html,hi"))
        XCTAssertEqual(store.bookmarks.filter { URLNormalizer.normalized($0.url) == URLNormalizer.normalized("https://dupe.example/") }.count, 1)
    }

    func testHistoryTableIsNeverQueried() {
        XCTAssertFalse(PlacesDatabase.bookmarkQuery.contains("moz_historyvisits"))
        XCTAssertFalse(PlacesDatabase.bookmarkQuery.contains("history"))
        XCTAssertTrue(PlacesDatabase.bookmarkQuery.contains("moz_bookmarks"))
        XCTAssertTrue(PlacesDatabase.bookmarkQuery.contains("LEFT JOIN moz_places"))
        XCTAssertTrue(PlacesDatabase.bookmarkQuery.contains("b.type IN (1, 2)"))
    }

    func testWalAndShmAreCopiedAndTempDeleted() throws {
        let url = try fixture("places", ext: "sqlite", subdirectory: "Fixtures/places-wal")
        let imported = try PlacesDatabase.importTree(from: url)
        XCTAssertTrue(imported.copiedWAL)
        XCTAssertTrue(imported.copiedSHM)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.tempDirectoryPath))
        let store = BookmarkStore(directory: directory)
        _ = BookmarkImport.merge(imported.nodes, into: store, sourceRoot: "Firefox")
        XCTAssertNotNil(store.bookmark(matchingURL: "https://wal.example/extra"))
    }

    func testProfileFolderResolvesPlacesSqlite() throws {
        let sqlite = try fixture("places", ext: "sqlite")
        let folder = sqlite.deletingLastPathComponent()
        let resolved = try PlacesDatabase.resolveDatabaseURL(folder, fileManager: .default)
        XCTAssertEqual(resolved.lastPathComponent, "places.sqlite")
    }

    func testHTMLEntitiesSchemeFilterTitleSanitizeAndDepthCap() throws {
        let url = try fixture("bookmarks", ext: "html")
        let nodes = try BookmarkHTMLParser.parse(data: Data(contentsOf: url))
        let titles = bookmarkTitles(nodes)
        XCTAssertTrue(titles.contains("Tom & Jerry"))
        XCTAssertTrue(titles.contains("Hello alert(1) world"))
        XCTAssertTrue(titles.contains("Deep leaf"))
        XCTAssertFalse(titles.contains { $0.contains("<script") })

        let store = BookmarkStore(directory: directory)
        let counts = BookmarkImport.merge(nodes, into: store, sourceRoot: "")
        XCTAssertNotNil(store.bookmark(matchingURL: "https://example.com/a"))
        XCTAssertNil(store.bookmark(matchingURL: "javascript:alert(1)"))
        XCTAssertNil(store.bookmark(matchingURL: "data:text/html,hi"))
        XCTAssertNil(store.bookmark(matchingURL: "vbscript:msg"))
        XCTAssertNil(store.bookmark(matchingURL: "file:///tmp/x"))
        XCTAssertNil(store.bookmark(matchingURL: "place:foo=1"))
        XCTAssertGreaterThan(counts.skippedUnsupported, 0)
        XCTAssertGreaterThan(counts.skippedDuplicates, 0)
        let deep = try XCTUnwrap(store.bookmark(matchingURL: "https://deep.example/leaf"))
        let depth = (deep.folder ?? "").split(separator: "/").count
        XCTAssertLessThanOrEqual(depth, BookmarkImport.maxFolderDepth)
        XCTAssertGreaterThan(depth, 0)
    }

    func testHTMLFileSizeCap() {
        let huge = Data(repeating: UInt8(ascii: "a"), count: BookmarkImport.maxFileSize + 1)
        XCTAssertThrowsError(try BookmarkHTMLParser.parse(data: huge)) { error in
            XCTAssertEqual(error as? BookmarkImportError, .fileTooLarge)
        }
    }

    func testBrowserFamilyJSONAndDedupeAgainstExisting() throws {
        let url = try fixture("browser-family", ext: "json")
        let nodes = try BrowserFamilyBookmarkParser.parse(data: Data(contentsOf: url))
        let store = BookmarkStore(directory: directory)
        _ = store.add(title: "Already", url: "https://example.com/")
        let counts = BookmarkImport.merge(nodes, into: store, sourceRoot: "Browser family")
        XCTAssertNotNil(store.bookmark(matchingURL: "https://docs.example.org/"))
        XCTAssertEqual(store.bookmark(matchingURL: "https://docs.example.org/")?.folder, "Browser family/Bookmarks Bar/Dev")
        XCTAssertNil(store.bookmark(matchingURL: "javascript:alert(1)"))
        XCTAssertNotNil(store.bookmark(matchingURL: "http://localhost/other"))
        XCTAssertGreaterThanOrEqual(counts.skippedDuplicates, 1)
        XCTAssertEqual(store.bookmarks.filter { URLNormalizer.normalized($0.url) == URLNormalizer.normalized("https://example.com/") }.count, 1)
    }

    func testTitleCapAndControlCharacters() {
        let long = String(repeating: "a", count: 600)
        let sanitized = BookmarkText.sanitizeTitle("<b>\u{0007}\(long)</b>")
        XCTAssertEqual(sanitized.count, BookmarkText.maxTitleLength)
        XCTAssertFalse(sanitized.contains("<"))
        XCTAssertFalse(sanitized.contains("\u{0007}"))
    }

    func testUnsupportedSchemes() {
        XCTAssertFalse(BookmarkImport.isSupportedURL("javascript:alert(1)"))
        XCTAssertFalse(BookmarkImport.isSupportedURL("data:text/html,x"))
        XCTAssertFalse(BookmarkImport.isSupportedURL("vbscript:x"))
        XCTAssertFalse(BookmarkImport.isSupportedURL("file:///tmp/x"))
        XCTAssertFalse(BookmarkImport.isSupportedURL("place:foo=1"))
        XCTAssertTrue(BookmarkImport.isSupportedURL("https://example.com"))
        XCTAssertTrue(BookmarkImport.isSupportedURL("http://localhost/x"))
    }

    private func fixture(_ name: String, ext: String, subdirectory: String = "Fixtures") throws -> URL {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
        #else
        let url = Bundle(for: BookmarkImportTests.self).url(forResource: name, withExtension: ext, subdirectory: subdirectory)
        #endif
        return try XCTUnwrap(url)
    }

    private func folderNames(_ nodes: [ImportedNode]) -> Set<String> {
        var names: Set<String> = []
        func walk(_ nodes: [ImportedNode]) {
            for node in nodes {
                if case .folder(let title, let children) = node {
                    names.insert(title)
                    walk(children)
                }
            }
        }
        walk(nodes)
        return names
    }

    private func bookmarkTitles(_ nodes: [ImportedNode]) -> [String] {
        var titles: [String] = []
        func walk(_ nodes: [ImportedNode]) {
            for node in nodes {
                switch node {
                case .folder(_, let children):
                    walk(children)
                case .bookmark(let title, _, _):
                    titles.append(title)
                }
            }
        }
        walk(nodes)
        return titles
    }
}
