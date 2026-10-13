// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum AtomicInstallError: Error, Equatable, Sendable {
    case codesignFailed
    case bundleMismatch
    case moveFailed
    case restoreFailed
    case unsignedRefused
    case checksumMismatch
    case mountFailed
    case appNotFound
    case notInstalledAsApp
    case translocated
    case notWritable
}

public protocol UpdateFileOps {
    func moveItem(at: URL, to: URL) throws
    func copyItem(at: URL, to: URL) throws
    func removeItem(at: URL) throws
    func fileExists(at: URL) -> Bool
    func verifyCodeSign(at: URL, expectedBundleID: String) throws
    func bundleIdentifier(at: URL) throws -> String
}

public struct AtomicSwapResult: Equatable, Sendable {
    public var backupURL: URL
    public var installedURL: URL

    public init(backupURL: URL, installedURL: URL) {
        self.backupURL = backupURL
        self.installedURL = installedURL
    }
}

public enum UpdateAtomicInstall {
    public static func backupName(for app: URL, timestamp: String) -> URL {
        let name = app.deletingPathExtension().lastPathComponent
        return app.deletingLastPathComponent()
            .appendingPathComponent("\(name).app.backup-\(timestamp)", isDirectory: true)
    }

    /// True when `candidate` is a backup this updater would have made for `installed`:
    /// same folder, `<name>.app.backup-<timestamp>`. Guards deletion of a stored path.
    public static func isBackup(_ candidate: URL, of installed: URL) -> Bool {
        let folder = installed.deletingLastPathComponent().standardizedFileURL.path
        guard candidate.deletingLastPathComponent().standardizedFileURL.path == folder else { return false }
        let prefix = installed.deletingPathExtension().lastPathComponent + ".app.backup-"
        let name = candidate.lastPathComponent
        guard name.hasPrefix(prefix), name.count > prefix.count else { return false }
        return !name.contains("/")
    }

    /// Letters, digits, `.`, `-`, `_` only, so the id is safe inside a code requirement string.
    public static func isValidBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 255 && !id.hasPrefix(".") && !id.hasSuffix(".")
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// Verify, move the installed app aside, move the new one in, verify again.
    /// Any failure after the first move puts the previous app back.
    public static func swap(
        installed: URL,
        incoming: URL,
        ops: UpdateFileOps,
        expectedBundleID: String,
        timestamp: String
    ) throws -> AtomicSwapResult {
        guard isValidBundleID(expectedBundleID) else { throw AtomicInstallError.codesignFailed }
        try ops.verifyCodeSign(at: incoming, expectedBundleID: expectedBundleID)
        let incomingID = try ops.bundleIdentifier(at: incoming)
        guard incomingID == expectedBundleID else {
            throw AtomicInstallError.bundleMismatch
        }
        let backup = backupName(for: installed, timestamp: timestamp)
        guard !ops.fileExists(at: backup) else { throw AtomicInstallError.moveFailed }
        try ops.moveItem(at: installed, to: backup)
        do {
            try ops.moveItem(at: incoming, to: installed)
        } catch {
            if ops.fileExists(at: backup) {
                do {
                    try ops.moveItem(at: backup, to: installed)
                } catch {
                    throw AtomicInstallError.restoreFailed
                }
            }
            throw AtomicInstallError.moveFailed
        }
        do {
            try ops.verifyCodeSign(at: installed, expectedBundleID: expectedBundleID)
            guard try ops.bundleIdentifier(at: installed) == expectedBundleID else {
                throw AtomicInstallError.bundleMismatch
            }
        } catch {
            do {
                try ops.moveItem(at: installed, to: incoming)
                try ops.moveItem(at: backup, to: installed)
            } catch {
                throw AtomicInstallError.restoreFailed
            }
            throw AtomicInstallError.codesignFailed
        }
        return AtomicSwapResult(backupURL: backup, installedURL: installed)
    }
}

public final class MemoryFileOps: UpdateFileOps {
    public var files: Set<String>
    public var identifiers: [String: String]
    public var failCodeSign = false
    /// 1-based codesign call that fails; call 2 is the check after the swap.
    public var failCodeSignOnCall: Int?
    public private(set) var codeSignCalls = 0
    public var failFirstMove = false
    public var failSecondMove = false
    public var failRestore = false
    public var moves: [(String, String)] = []
    private var skippedSecond = false

    public init(files: Set<String>, identifiers: [String: String] = [:]) {
        self.files = files
        self.identifiers = identifiers
    }

    public func moveItem(at: URL, to: URL) throws {
        if failFirstMove, moves.isEmpty {
            throw AtomicInstallError.moveFailed
        }
        if failSecondMove, moves.count == 1, !skippedSecond {
            skippedSecond = true
            throw AtomicInstallError.moveFailed
        }
        if failRestore, moves.count >= 2 {
            throw AtomicInstallError.restoreFailed
        }
        guard files.contains(at.path) else { throw AtomicInstallError.moveFailed }
        files.remove(at.path)
        files.insert(to.path)
        if let id = identifiers[at.path] {
            identifiers[to.path] = id
            identifiers.removeValue(forKey: at.path)
        }
        moves.append((at.path, to.path))
    }

    public func copyItem(at: URL, to: URL) throws {
        guard files.contains(at.path) else { throw AtomicInstallError.moveFailed }
        files.insert(to.path)
        identifiers[to.path] = identifiers[at.path]
    }

    public func removeItem(at: URL) throws {
        files.remove(at.path)
        identifiers.removeValue(forKey: at.path)
    }

    public func fileExists(at: URL) -> Bool {
        files.contains(at.path)
    }

    public func verifyCodeSign(at: URL, expectedBundleID: String) throws {
        codeSignCalls += 1
        if failCodeSignOnCall == codeSignCalls { throw AtomicInstallError.codesignFailed }
        if failCodeSign || expectedBundleID.isEmpty { throw AtomicInstallError.codesignFailed }
        guard files.contains(at.path) else { throw AtomicInstallError.codesignFailed }
    }

    public func bundleIdentifier(at: URL) throws -> String {
        guard let id = identifiers[at.path] else { throw AtomicInstallError.bundleMismatch }
        return id
    }
}

/// Real file operations for a live install. Tests inject `MemoryFileOps` instead.
public struct DiskFileOps: UpdateFileOps {
    public init() {}

    public func moveItem(at: URL, to: URL) throws {
        try FileManager.default.moveItem(at: at, to: to)
    }

    public func copyItem(at: URL, to: URL) throws {
        try FileManager.default.copyItem(at: at, to: to)
    }

    public func removeItem(at: URL) throws {
        try FileManager.default.removeItem(at: at)
    }

    public func fileExists(at: URL) -> Bool {
        FileManager.default.fileExists(atPath: at.path)
    }

    /// Ad-hoc signatures satisfy an identifier requirement only. There is no Developer ID anchor.
    /// Arguments go to codesign as an array; the id is checked to reverse-DNS characters first.
    public func verifyCodeSign(at: URL, expectedBundleID: String) throws {
        guard UpdateAtomicInstall.isValidBundleID(expectedBundleID) else { throw AtomicInstallError.codesignFailed }
        let requirement = "=identifier \"\(expectedBundleID)\""
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--verify", "--deep", "--strict", "-R", requirement, at.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw AtomicInstallError.codesignFailed }
    }

    public func bundleIdentifier(at: URL) throws -> String {
        let plist = at.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plist)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = object as? [String: Any],
              let id = dict["CFBundleIdentifier"] as? String else {
            throw AtomicInstallError.bundleMismatch
        }
        return id
    }
}
