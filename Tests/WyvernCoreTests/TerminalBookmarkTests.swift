// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class TerminalBookmarkTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mode(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testArgumentsKeepTheCommandAsOneElement() {
        let command = "echo \"hi $USER\" && ls 'a b'"
        XCTAssertEqual(
            TerminalLaunch.arguments(shell: "/bin/zsh", command: command),
            ["/bin/zsh", "-lc", command]
        )
    }

    func testLoginShellIsAbsolute() {
        let shell = TerminalLaunch.loginShellPath()
        XCTAssertTrue(shell.hasPrefix("/"))
        XCTAssertFalse(shell.contains("\n"))
    }

    func testAddRequiresNameAndCommandAndStartsUnconfirmed() throws {
        let directory = try temporaryDirectory()
        let store = TerminalBookmarkStore(directory: directory)
        XCTAssertNil(store.add(name: "  ", command: "echo"))
        XCTAssertNil(store.add(name: "Echo", command: ""))
        let added = try XCTUnwrap(store.add(name: "  Echo  ", command: "echo hi"))
        XCTAssertEqual(added.name, "Echo")
        XCTAssertTrue(added.enabled)
        XCTAssertNil(added.confirmedCommandHash)
        XCTAssertTrue(added.needsConfirmation)
        XCTAssertFalse(added.canLaunch)
        XCTAssertTrue(TerminalBookmarkStore.sharingWarning.contains("privileges"))
    }

    func testConfirmAndCommandEdit() throws {
        let directory = try temporaryDirectory()
        let store = TerminalBookmarkStore(directory: directory)
        let added = try XCTUnwrap(store.add(name: "Echo", command: "echo hi"))
        store.confirm(id: added.id)
        let confirmed = try XCTUnwrap(store.bookmark(id: added.id))
        XCTAssertEqual(confirmed.confirmedCommandHash, TerminalCommandHash.hex("echo hi"))
        XCTAssertTrue(confirmed.canLaunch)
        store.update(id: added.id, name: "Echo", command: "echo hi")
        XCTAssertTrue(try XCTUnwrap(store.bookmark(id: added.id)).canLaunch)
        store.update(id: added.id, name: "Echo", command: "echo there")
        let edited = try XCTUnwrap(store.bookmark(id: added.id))
        XCTAssertNil(edited.confirmedCommandHash)
        XCTAssertTrue(edited.needsConfirmation)
        XCTAssertFalse(edited.canLaunch)
    }

    func testEnableDoesNotConfirm() throws {
        let directory = try temporaryDirectory()
        let store = TerminalBookmarkStore(directory: directory)
        let added = try XCTUnwrap(store.add(name: "Echo", command: "echo hi"))
        store.setEnabled(false, id: added.id)
        store.confirm(id: added.id)
        XCTAssertFalse(try XCTUnwrap(store.bookmark(id: added.id)).canLaunch)
        store.setEnabled(true, id: added.id)
        XCTAssertTrue(try XCTUnwrap(store.bookmark(id: added.id)).canLaunch)
        XCTAssertEqual(store.enabledBookmarks.count, 1)
    }

    func testImportStaysDisabledAndUnconfirmed() throws {
        let directory = try temporaryDirectory()
        let store = TerminalBookmarkStore(directory: directory)
        let command = "printf ready"
        let incoming = TerminalBookmark(
            name: "Imported",
            command: command,
            enabled: true,
            confirmedCommandHash: TerminalCommandHash.hex(command)
        )
        store.importBookmarks([incoming])
        let stored = try XCTUnwrap(store.bookmarks.first)
        XCTAssertFalse(stored.enabled)
        XCTAssertNil(stored.confirmedCommandHash)
        XCTAssertFalse(stored.canLaunch)
        XCTAssertTrue(store.enabledBookmarks.isEmpty)
    }

    func testFileModeIsOwnerOnlyAndDirectoryIsUnchanged() throws {
        let directory = try temporaryDirectory()
        let before = mode(of: directory)
        let store = TerminalBookmarkStore(directory: directory)
        _ = store.add(name: "Echo", command: "echo hi")
        XCTAssertEqual(mode(of: store.fileURL) & 0o777, 0o600)
        XCTAssertNotEqual(mode(of: directory) & 0o777, 0o600)
        XCTAssertEqual(mode(of: directory), before)
        let loaded = TerminalBookmarkStore(directory: directory)
        XCTAssertEqual(loaded.bookmarks.map(\.command), ["echo hi"])
        XCTAssertEqual(mode(of: loaded.fileURL) & 0o777, 0o600)
    }

    func testCorruptFileIsQuarantined() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(AppInfo.terminalBookmarksFileName)
        try Data("not-json".utf8).write(to: url)
        let store = TerminalBookmarkStore(directory: directory)
        XCTAssertTrue(store.bookmarks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }

    func testShellOrDirectoryChangeClearsConfirmation() throws {
        let directory = try temporaryDirectory()
        let store = TerminalBookmarkStore(directory: directory)
        let added = try XCTUnwrap(store.add(name: "Echo", command: "echo hi"))
        store.confirm(id: added.id)
        store.update(id: added.id, name: "Echo", command: "echo hi", workingDirectory: "/tmp")
        XCTAssertNil(try XCTUnwrap(store.bookmark(id: added.id)).confirmedCommandHash)
        XCTAssertEqual(try XCTUnwrap(store.bookmark(id: added.id)).workingDirectory, "/tmp")
        store.confirm(id: added.id)
        store.update(id: added.id, name: "Echo", command: "echo hi", shell: "/bin/bash")
        let afterShell = try XCTUnwrap(store.bookmark(id: added.id))
        XCTAssertNil(afterShell.confirmedCommandHash)
        XCTAssertEqual(afterShell.workingDirectory, "/tmp")
        XCTAssertEqual(afterShell.shell, "/bin/bash")
        store.confirm(id: added.id)
        store.update(id: added.id, name: "Echo", command: "echo hi", openInNewTab: false)
        let afterTab = try XCTUnwrap(store.bookmark(id: added.id))
        XCTAssertEqual(afterTab.confirmedCommandHash, TerminalCommandHash.hex("echo hi"))
        XCTAssertFalse(afterTab.openInNewTab)
        XCTAssertEqual(afterTab.shell, "/bin/bash")
    }

    func testLegacyJSONKeepsDefaultsForNewFields() throws {
        let directory = try temporaryDirectory()
        let id = UUID()
        let json = """
        {"version":1,"bookmarks":[{"command":"echo hi","enabled":true,"id":"\(id.uuidString)","name":"Echo"}]}
        """
        let url = directory.appendingPathComponent(AppInfo.terminalBookmarksFileName)
        try Data(json.utf8).write(to: url)
        let store = TerminalBookmarkStore(directory: directory)
        let stored = try XCTUnwrap(store.bookmarks.first)
        XCTAssertEqual(stored.name, "Echo")
        XCTAssertEqual(stored.command, "echo hi")
        XCTAssertEqual(stored.workingDirectory, "")
        XCTAssertEqual(stored.shell, "")
        XCTAssertTrue(stored.openInNewTab)
        XCTAssertTrue(stored.enabled)
    }

    func testResolvedShellRejectsRelativeAndNewline() {
        XCTAssertEqual(TerminalLaunch.resolvedShell(bookmarkShell: "/bin/bash", defaultShell: "zsh"), "/bin/bash")
        XCTAssertEqual(TerminalLaunch.resolvedShell(bookmarkShell: "zsh", defaultShell: "/bin/sh"), "/bin/sh")
        XCTAssertEqual(
            TerminalLaunch.resolvedShell(bookmarkShell: "/bin/bash\n", defaultShell: "/bin/sh"),
            "/bin/sh"
        )
        XCTAssertEqual(
            TerminalLaunch.resolvedShell(bookmarkShell: "relative", defaultShell: "/tmp/nope\u{0}"),
            TerminalLaunch.loginShellPath()
        )
        XCTAssertEqual(TerminalLaunch.resolvedShell(bookmarkShell: "  ", defaultShell: ""), TerminalLaunch.loginShellPath())
    }

    func testExpandedDirectoryAndCaption() {
        XCTAssertNil(TerminalLaunch.expandedDirectory(""))
        XCTAssertNil(TerminalLaunch.expandedDirectory("~"))
        XCTAssertNil(TerminalLaunch.expandedDirectory("~/"))
        XCTAssertNil(TerminalLaunch.expandedDirectory("relative/path"))
        XCTAssertNil(TerminalLaunch.expandedDirectory("/tmp\n"))
        XCTAssertNil(TerminalLaunch.expandedDirectory("/tmp\u{0}"))
        XCTAssertEqual(TerminalLaunch.expandedDirectory("/tmp"), "/tmp")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(TerminalLaunch.expandedDirectory("~/docs"), home + "/docs")
        XCTAssertEqual(TerminalLaunch.fieldCaption(shell: "/bin/zsh", directory: ""), "zsh  ~")
        XCTAssertEqual(TerminalLaunch.fieldCaption(shell: "/bin/zsh", directory: "~/proj"), "zsh  ~/proj")
    }

    func testConfirmationNamesShellAndDirectoryWithoutChangingTheHash() throws {
        let text = TerminalLaunch.confirmationText(
            command: "echo hi",
            shell: "/tmp/custom-shell",
            workingDirectory: "/var/work"
        )
        XCTAssertTrue(text.contains("Shell: /tmp/custom-shell"))
        XCTAssertTrue(text.contains("Working directory: /var/work"))
        XCTAssertTrue(text.contains("Command: echo hi"))
        let shellAt = try XCTUnwrap(text.range(of: "Shell:"))
        let directoryAt = try XCTUnwrap(text.range(of: "Working directory:"))
        let commandAt = try XCTUnwrap(text.range(of: "Command:"))
        XCTAssertLessThan(shellAt.lowerBound, directoryAt.lowerBound)
        XCTAssertLessThan(directoryAt.lowerBound, commandAt.lowerBound)

        let home = TerminalLaunch.confirmationText(command: "echo hi", shell: "/bin/zsh", workingDirectory: nil)
        XCTAssertEqual(home, "Shell: /bin/zsh\nWorking directory: ~\nCommand: echo hi")
        let blank = TerminalLaunch.confirmationText(command: "echo hi", shell: "  ", workingDirectory: "  ")
        XCTAssertTrue(blank.contains("Shell: (login shell)"))
        XCTAssertTrue(blank.contains("Working directory: ~"))

        let hash = TerminalCommandHash.hex("echo hi")
        let bookmark = TerminalBookmark(
            name: "Echo",
            command: "echo hi",
            enabled: true,
            confirmedCommandHash: hash,
            workingDirectory: "/var/work",
            shell: "/tmp/custom-shell"
        )
        XCTAssertFalse(bookmark.needsConfirmation)
        XCTAssertTrue(bookmark.canLaunch)
        XCTAssertEqual(bookmark.confirmedCommandHash, TerminalCommandHash.hex(bookmark.command))
    }

    func testRemoveAndMissingUpdate() throws {
        let directory = try temporaryDirectory()
        let store = TerminalBookmarkStore(directory: directory)
        let added = try XCTUnwrap(store.add(name: "Echo", command: "echo hi"))
        store.update(id: UUID(), name: "Other", command: "true")
        XCTAssertEqual(store.bookmarks.count, 1)
        store.remove(id: added.id)
        XCTAssertTrue(store.bookmarks.isEmpty)
        let loaded = TerminalBookmarkStore(directory: directory)
        XCTAssertTrue(loaded.bookmarks.isEmpty)
    }
}
