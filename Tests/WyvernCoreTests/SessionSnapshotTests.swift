// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class SessionSnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testEncodeDecodeRoundTrip() throws {
        let bookmark = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let snapshot = SessionSnapshot(windows: [
            SessionWindowSnapshot(tabs: [
                SessionTabSnapshot(kind: .web, url: "https://example.com/a"),
                SessionTabSnapshot(kind: .terminal, terminalBookmarkID: bookmark),
                SessionTabSnapshot(kind: .web, url: nil)
            ], selectedIndex: 1),
            SessionWindowSnapshot(tabs: [
                SessionTabSnapshot(kind: .web, url: "wyvern://bookmarks")
            ], selectedIndex: 0)
        ])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.windows[0].tabs[1].kind, .terminal)
        XCTAssertEqual(decoded.windows[0].tabs[1].terminalBookmarkID, bookmark)
        XCTAssertNil(decoded.windows[0].tabs[1].url)
        XCTAssertEqual(decoded.windows[0].selectedIndex, 1)
        XCTAssertTrue(decoded.hasRestorableTabs)
    }

    func testSelectedIndexClampsAndMissingKeysDefault() throws {
        let high = try JSONDecoder().decode(
            SessionWindowSnapshot.self,
            from: Data(#"{"tabs":[{"kind":"web","url":"https://example.com"}],"selectedIndex":9}"#.utf8)
        )
        XCTAssertEqual(high.selectedIndex, 0)
        let negative = SessionWindowSnapshot(
            tabs: [SessionTabSnapshot(kind: .web, url: "https://example.com")],
            selectedIndex: -3
        )
        XCTAssertEqual(negative.selectedIndex, 0)
        let empty = try JSONDecoder().decode(SessionSnapshot.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.windows, [])
        XCTAssertFalse(empty.hasRestorableTabs)
        let window = try JSONDecoder().decode(SessionWindowSnapshot.self, from: Data("{}".utf8))
        XCTAssertEqual(window.tabs, [])
        XCTAssertEqual(window.selectedIndex, 0)
        XCTAssertNil(window.tile)
    }

    func testOldSnapshotWithoutTileDecodes() throws {
        let json = """
        {"windows":[{"tabs":[{"kind":"web","url":"https://example.com/a"},{"kind":"terminal","terminalBookmarkID":"11111111-2222-3333-4444-555555555555"},{"kind":"web"}],"selectedIndex":1}]}
        """
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.windows.count, 1)
        XCTAssertEqual(decoded.windows[0].tabs.count, 3)
        XCTAssertEqual(decoded.windows[0].selectedIndex, 1)
        XCTAssertNil(decoded.windows[0].tile)
        XCTAssertEqual(decoded.windows[0].tabs[0].url, "https://example.com/a")
        XCTAssertEqual(decoded.windows[0].tabs[1].kind, .terminal)
        XCTAssertNil(decoded.windows[0].tabs[2].url)
    }

    func testCorruptTileDoesNotDropTheWindow() throws {
        let json = """
        {"tabs":[{"kind":"web","url":"https://example.com"}],"selectedIndex":0,"tile":"nope"}
        """
        let decoded = try JSONDecoder().decode(SessionWindowSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tabs.count, 1)
        XCTAssertEqual(decoded.selectedIndex, 0)
        XCTAssertNil(decoded.tile)
        XCTAssertEqual(decoded.tabs[0].url, "https://example.com")
    }

    func testMissingCleanExitCountsAsClean() {
        let archive = SessionArchive(directory: directory)
        XCTAssertTrue(archive.readCleanExit())
        XCTAssertTrue(archive.writeCleanExit(false))
        XCTAssertFalse(archive.readCleanExit())
        XCTAssertTrue(archive.writeCleanExit(true))
        XCTAssertTrue(archive.readCleanExit())
    }

    func testBeginRunUncleanOffersRestoreAndMarksThisRunUnclean() throws {
        let archive = SessionArchive(directory: directory)
        let snapshot = SessionSnapshot(windows: [
            SessionWindowSnapshot(tabs: [
                SessionTabSnapshot(kind: .web, url: "https://example.com")
            ], selectedIndex: 0)
        ])
        XCTAssertTrue(archive.saveLive(snapshot))
        XCTAssertTrue(archive.writeCleanExit(false))
        let state = archive.beginRun()
        XCTAssertFalse(state.wasCleanExit)
        XCTAssertTrue(state.offerCrashRestore)
        XCTAssertEqual(state.previous, snapshot)
        XCTAssertFalse(archive.readCleanExit())
        XCTAssertEqual(archive.loadPrevious(), snapshot)
    }

    func testBeginRunCleanKeepsPreviousWithoutOffering() {
        let archive = SessionArchive(directory: directory)
        let snapshot = SessionSnapshot(windows: [
            SessionWindowSnapshot(tabs: [
                SessionTabSnapshot(kind: .terminal, terminalBookmarkID: UUID())
            ], selectedIndex: 0)
        ])
        XCTAssertTrue(archive.saveLive(snapshot))
        XCTAssertTrue(archive.writeCleanExit(true))
        let state = archive.beginRun()
        XCTAssertTrue(state.wasCleanExit)
        XCTAssertFalse(state.offerCrashRestore)
        XCTAssertEqual(state.previous, snapshot)
        XCTAssertFalse(archive.readCleanExit())
        XCTAssertTrue(archive.loadPrevious()?.hasRestorableTabs == true)
    }

    func testBeginRunWithoutSnapshotOrEmptySnapshotDoesNotOffer() {
        let archive = SessionArchive(directory: directory)
        XCTAssertTrue(archive.writeCleanExit(false))
        let missing = archive.beginRun()
        XCTAssertFalse(missing.offerCrashRestore)
        XCTAssertNil(missing.previous)
        XCTAssertFalse(archive.readCleanExit())

        let empty = SessionSnapshot(windows: [SessionWindowSnapshot(tabs: [], selectedIndex: 4)])
        XCTAssertTrue(archive.saveLive(empty))
        XCTAssertTrue(archive.writeCleanExit(false))
        let state = archive.beginRun()
        XCTAssertFalse(state.offerCrashRestore)
        XCTAssertEqual(state.previous, empty)
        XCTAssertEqual(state.previous?.windows.first?.selectedIndex, 0)
    }

    func testCorruptSnapshotIsIgnored() {
        let archive = SessionArchive(directory: directory)
        try? Data("nope".utf8).write(to: archive.liveURL)
        XCTAssertTrue(archive.writeCleanExit(false))
        let state = archive.beginRun()
        XCTAssertNil(state.previous)
        XCTAssertFalse(state.offerCrashRestore)
    }

    func testStartupChoiceLetsCrashRestoreWin() {
        XCTAssertEqual(
            SessionStartup.choice(offerCrashRestore: true, startupPage: .restoreLastSession, startupURL: "https://example.com"),
            .offerCrashRestore
        )
        XCTAssertEqual(
            SessionStartup.choice(offerCrashRestore: false, startupPage: .newTab, startupURL: ""),
            .newTab
        )
        XCTAssertEqual(
            SessionStartup.choice(offerCrashRestore: false, startupPage: .restoreLastSession, startupURL: ""),
            .restoreLastSession
        )
        XCTAssertEqual(
            SessionStartup.choice(offerCrashRestore: false, startupPage: .customURL, startupURL: "  https://example.com  "),
            .customURL("https://example.com")
        )
        XCTAssertEqual(
            SessionStartup.choice(offerCrashRestore: false, startupPage: .customURL, startupURL: "   "),
            .newTab
        )
    }

    func testRestoreDropsScriptAndNonHTMLFiles() {
        XCTAssertEqual(
            SessionRestorePolicy.webLoad(for: "https://example.com/a"),
            .web(URL(string: "https://example.com/a")!)
        )
        XCTAssertEqual(SessionRestorePolicy.webLoad(for: "javascript:alert(1)"), .newTab)
        XCTAssertEqual(SessionRestorePolicy.webLoad(for: "data:text/html,hi"), .newTab)
        XCTAssertEqual(SessionRestorePolicy.webLoad(for: "file:///tmp/notes.txt"), .newTab)
        XCTAssertEqual(
            SessionRestorePolicy.webLoad(for: "file:///tmp/page.html"),
            .localDocument(URL(string: "file:///tmp/page.html")!)
        )
        XCTAssertEqual(SessionRestorePolicy.webLoad(for: nil), .newTab)
        let huge = Data(repeating: UInt8(ascii: "{"), count: 64)
        XCTAssertNil(SessionRestorePolicy.decodeSnapshot(huge, maxBytes: 32))
        let small = Data("{\"windows\":[]}".utf8)
        XCTAssertEqual(SessionRestorePolicy.decodeSnapshot(small, maxBytes: 32)?.windows.count, 0)
    }

    func testOversizedSnapshotFileIsNotRead() throws {
        let archive = SessionArchive(directory: directory)
        try Data(repeating: UInt8(ascii: "x"), count: 64).write(to: archive.liveURL)
        XCTAssertNil(SessionArchive.loadSnapshot(at: archive.liveURL, maxBytes: 16))
    }

    func testMarkCleanExitAfterBeginRun() {
        let archive = SessionArchive(directory: directory)
        _ = archive.beginRun()
        XCTAssertFalse(archive.readCleanExit())
        archive.markCleanExit()
        XCTAssertTrue(archive.readCleanExit())
    }
}
