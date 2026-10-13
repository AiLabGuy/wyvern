// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import App1Core

final class UpdateAtomicTests: XCTestCase {
    private let installed = URL(fileURLWithPath: "/tmp/Wyvern Browser.app")
    private let incoming = URL(fileURLWithPath: "/tmp/incoming.app")
    private let bundleID = AppInfo.fallbackBundleIdentifier

    func testSuccessfulSwap() throws {
        let ops = MemoryFileOps(
            files: [installed.path, incoming.path],
            identifiers: [incoming.path: bundleID, installed.path: bundleID]
        )
        let result = try UpdateAtomicInstall.swap(
            installed: installed,
            incoming: incoming,
            ops: ops,
            expectedBundleID: bundleID,
            timestamp: "1"
        )
        XCTAssertTrue(ops.fileExists(at: installed))
        XCTAssertFalse(ops.fileExists(at: incoming))
        XCTAssertTrue(ops.fileExists(at: result.backupURL))
    }

    func testCodeSignFailureLeavesInstalled() {
        let ops = MemoryFileOps(
            files: [installed.path, incoming.path],
            identifiers: [incoming.path: bundleID, installed.path: bundleID]
        )
        ops.failCodeSign = true
        XCTAssertThrowsError(
            try UpdateAtomicInstall.swap(
                installed: installed,
                incoming: incoming,
                ops: ops,
                expectedBundleID: bundleID,
                timestamp: "1"
            )
        )
        XCTAssertTrue(ops.fileExists(at: installed))
        XCTAssertTrue(ops.fileExists(at: incoming))
        XCTAssertEqual(ops.moves.count, 0)
    }

    func testBundleMismatchLeavesInstalled() {
        let ops = MemoryFileOps(
            files: [installed.path, incoming.path],
            identifiers: [incoming.path: "other.id", installed.path: bundleID]
        )
        XCTAssertThrowsError(
            try UpdateAtomicInstall.swap(
                installed: installed,
                incoming: incoming,
                ops: ops,
                expectedBundleID: bundleID,
                timestamp: "1"
            )
        )
        XCTAssertTrue(ops.fileExists(at: installed))
        XCTAssertEqual(ops.moves.count, 0)
    }

    func testFirstMoveFailureLeavesInstalled() {
        let ops = MemoryFileOps(
            files: [installed.path, incoming.path],
            identifiers: [incoming.path: bundleID, installed.path: bundleID]
        )
        ops.failFirstMove = true
        XCTAssertThrowsError(
            try UpdateAtomicInstall.swap(
                installed: installed,
                incoming: incoming,
                ops: ops,
                expectedBundleID: bundleID,
                timestamp: "1"
            )
        )
        XCTAssertTrue(ops.fileExists(at: installed))
        XCTAssertTrue(ops.fileExists(at: incoming))
    }

    /// The new app is checked again in place; a failure there puts the previous app back.
    func testPostSwapCodeSignFailureRollsBack() {
        let ops = MemoryFileOps(
            files: [installed.path, incoming.path],
            identifiers: [incoming.path: bundleID, installed.path: bundleID]
        )
        ops.failCodeSignOnCall = 2
        XCTAssertThrowsError(
            try UpdateAtomicInstall.swap(
                installed: installed,
                incoming: incoming,
                ops: ops,
                expectedBundleID: bundleID,
                timestamp: "1"
            )
        ) { error in
            XCTAssertEqual(error as? AtomicInstallError, .codesignFailed)
        }
        let backup = UpdateAtomicInstall.backupName(for: installed, timestamp: "1")
        XCTAssertTrue(ops.fileExists(at: installed))
        XCTAssertFalse(ops.fileExists(at: backup))
        XCTAssertTrue(ops.fileExists(at: incoming))
        XCTAssertEqual(ops.moves.last?.0, backup.path)
        XCTAssertEqual(ops.moves.last?.1, installed.path)
    }

    func testRequirementUnsafeBundleIDRefused() {
        let ops = MemoryFileOps(files: [installed.path, incoming.path], identifiers: [incoming.path: "a\" or \"b"])
        XCTAssertThrowsError(
            try UpdateAtomicInstall.swap(
                installed: installed,
                incoming: incoming,
                ops: ops,
                expectedBundleID: "a\" or \"b",
                timestamp: "1"
            )
        ) { error in
            XCTAssertEqual(error as? AtomicInstallError, .codesignFailed)
        }
        XCTAssertEqual(ops.moves.count, 0)
        XCTAssertTrue(UpdateAtomicInstall.isValidBundleID(bundleID))
        XCTAssertFalse(UpdateAtomicInstall.isValidBundleID(""))
        XCTAssertFalse(UpdateAtomicInstall.isValidBundleID("a b"))
    }

    func testBackupPathGuard() {
        let app = URL(fileURLWithPath: "/Applications/Wyvern Browser.app")
        XCTAssertTrue(UpdateAtomicInstall.isBackup(
            UpdateAtomicInstall.backupName(for: app, timestamp: "20260101T000000Z"),
            of: app
        ))
        XCTAssertFalse(UpdateAtomicInstall.isBackup(URL(fileURLWithPath: "/Users/someone/Documents"), of: app))
        XCTAssertFalse(UpdateAtomicInstall.isBackup(URL(fileURLWithPath: "/Applications/Other.app"), of: app))
        XCTAssertFalse(UpdateAtomicInstall.isBackup(
            URL(fileURLWithPath: "/tmp/Wyvern Browser.app.backup-1"),
            of: app
        ))
        XCTAssertFalse(UpdateAtomicInstall.isBackup(URL(fileURLWithPath: "/Applications/Wyvern Browser.app.backup-"), of: app))
    }

    func testSecondMoveFailureRestoresBackup() {
        let ops = MemoryFileOps(
            files: [installed.path, incoming.path],
            identifiers: [incoming.path: bundleID, installed.path: bundleID]
        )
        ops.failSecondMove = true
        XCTAssertThrowsError(
            try UpdateAtomicInstall.swap(
                installed: installed,
                incoming: incoming,
                ops: ops,
                expectedBundleID: bundleID,
                timestamp: "1"
            )
        )
        XCTAssertTrue(ops.fileExists(at: installed))
        XCTAssertEqual(ops.identifiers[installed.path], bundleID)
    }
}
