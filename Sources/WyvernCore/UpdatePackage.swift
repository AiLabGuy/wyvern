// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum UpdatePackageError: Error, Equatable, Sendable {
    case tooLarge
    case badZipName
    case extractFailed
    case zipMalformed
    case unsupportedEntry(String)
    case pathTraversal(String)
    case duplicateEntry(String)
    case unexpectedEntry(String)
    case symlinkRejected
    case notRegularFile
    case missingMember
    case checksumNameMismatch
    case checksumMismatch
    case commentRejected
    case commentFileMismatch
    case zipNameMismatch
    /// The signed version, build, or commit differs from what the feed listed.
    case metadataMismatch
    case notNewer
}

/// Signed trusted comment. Space-separated `key=value` tokens in any order:
/// `version=<marketing> build=<CFBundleVersion> commit=<40 hex> [file=<dmg name>]`.
/// A leading `wyvern` token is accepted; CI writes it so older installs can still read the comment.
public struct TrustedUpdateComment: Equatable, Sendable {
    public var version: String
    public var build: String
    public var commit: String
    public var file: String?

    public init(version: String, build: String, commit: String, file: String?) {
        self.version = version
        self.build = build
        self.commit = commit
        self.file = file
    }

    public var line: String {
        var text = "wyvern version=\(version) build=\(build) commit=\(commit)"
        if let file {
            text += " file=\(file)"
        }
        return text
    }

    private static let knownKeys: Set<String> = ["version", "build", "commit", "file"]

    /// Call only with the comment returned by `Minisign.verify`. Values contain no spaces.
    public static func parse(_ raw: String) -> TrustedUpdateComment? {
        var tokens = raw.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if tokens.first == "wyvern" {
            tokens.removeFirst()
        }
        guard (3...4).contains(tokens.count), !tokens.contains(where: \.isEmpty) else { return nil }
        var values: [String: String] = [:]
        for token in tokens {
            guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return nil }
            let key = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
            guard knownKeys.contains(key), values[key] == nil else { return nil }
            guard !value.isEmpty, !value.contains("="), !value.contains("/"), !value.contains("\\") else {
                return nil
            }
            values[key] = value
        }
        guard let version = values["version"],
              let build = values["build"],
              let commit = values["commit"] else {
            return nil
        }
        guard UpdateVersion.isValidBuild(build), UpdateVersion.isValidVersion(version) else { return nil }
        guard UpdateVersion.isValidCommit(commit) else { return nil }
        return TrustedUpdateComment(version: version, build: build, commit: commit.lowercased(), file: values["file"])
    }
}

public struct UpdateZipName: Equatable, Sendable {
    public var basename: String
    public var version: String
    public var build: Int
    public var fileName: String

    public init(basename: String, version: String, build: Int, fileName: String) {
        self.basename = basename
        self.version = version
        self.build = build
        self.fileName = fileName
    }

    public var dmgName: String { "\(basename)-\(version).dmg" }
    public var shaName: String { dmgName + ".sha256" }
    public var sigName: String { dmgName + ".sha256.minisig" }
    public var memberNames: Set<String> { [dmgName, shaName, sigName] }

    /// Exact `<basename>-<version>-b<build>.zip`.
    public static func parse(fileName: String, basename: String) -> UpdateZipName? {
        let prefix = basename + "-"
        guard !basename.isEmpty, fileName.hasPrefix(prefix), fileName.hasSuffix(".zip") else { return nil }
        let middle = String(fileName.dropFirst(prefix.count).dropLast(4))
        guard let marker = middle.range(of: "-b", options: .backwards) else { return nil }
        let version = String(middle[..<marker.lowerBound])
        let buildText = String(middle[marker.upperBound...])
        guard UpdateVersion.isValidBuild(buildText), let build = Int(buildText) else { return nil }
        guard UpdateVersion.isValidVersion(version) else { return nil }
        return UpdateZipName(basename: basename, version: version, build: build, fileName: fileName)
    }
}

public struct VerifiedZip: Equatable, Sendable {
    public var directory: URL
    public var dmgURL: URL
    public var comment: TrustedUpdateComment
    public var zipName: UpdateZipName
    /// SHA-256 of the disk image at verification time. Install hashes the file again before mount.
    public var dmgSHA256: String

    public init(
        directory: URL,
        dmgURL: URL,
        comment: TrustedUpdateComment,
        zipName: UpdateZipName,
        dmgSHA256: String
    ) {
        self.directory = directory
        self.dmgURL = dmgURL
        self.comment = comment
        self.zipName = zipName
        self.dmgSHA256 = dmgSHA256
    }
}

public enum UpdatePackage {
    public static let maxZipBytes: Int64 = 500 * 1024 * 1024

    /// Inspect, extract, and verify a downloaded update zip.
    /// - `localVersion`/`localBuild` set: the signed version must be strictly newer.
    /// - `candidate` set: the signed version, build, and (when listed) commit must equal the feed's.
    /// The caller removes `VerifiedZip.directory` when done.
    public static func verifyZip(
        at zipURL: URL,
        encodedPublicKey: String,
        basename: String,
        localVersion: String? = nil,
        localBuild: String? = nil,
        candidate: UpdateCandidate? = nil
    ) throws -> VerifiedZip {
        let zipFileName = zipURL.lastPathComponent
        guard let zipName = UpdateZipName.parse(fileName: zipFileName, basename: basename) else {
            throw UpdatePackageError.badZipName
        }
        if let candidate, candidate.zipName != zipName {
            throw UpdatePackageError.metadataMismatch
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 || size > maxZipBytes {
            throw UpdatePackageError.tooLarge
        }
        // Every entry name is checked before any extractor touches the archive.
        let entries = try UpdateZipInspector.inspect(zipAt: zipURL, allowed: zipName.memberNames)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-zip-\(UUID().uuidString)", isDirectory: true)
        let payload = directory.appendingPathComponent("payload", isDirectory: true)
        do {
            try createPrivateDirectory(directory)
            try createPrivateDirectory(payload)
            try extract(zip: zipURL, into: payload)
            // Nothing may land beside the payload folder, whatever the extractor did.
            let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard siblings == ["payload"] else {
                throw UpdatePackageError.pathTraversal(siblings.filter { $0 != "payload" }.first ?? "")
            }
            let members = try validateMembers(in: payload, allowed: zipName.memberNames)
            try enforceExtractedSizes(members, declared: entries)
            guard let dmgURL = members[zipName.dmgName],
                  let shaURL = members[zipName.shaName],
                  let sigURL = members[zipName.sigName] else {
                throw UpdatePackageError.missingMember
            }
            let dmg = try Data(contentsOf: dmgURL, options: .alwaysMapped)
            let sha = try Data(contentsOf: shaURL)
            let sigText = String(data: try Data(contentsOf: sigURL), encoding: .utf8) ?? ""
            let comment = try verifyPayload(
                dmg: dmg,
                sha256File: sha,
                minisigText: sigText,
                encodedPublicKey: encodedPublicKey,
                expectedFileName: zipName.dmgName
            )
            guard comment.version == zipName.version, comment.build == String(zipName.build) else {
                throw UpdatePackageError.zipNameMismatch
            }
            if let candidate {
                try checkMetadata(comment, candidate: candidate)
            }
            if let localVersion, let localBuild {
                guard UpdateVersion.isNewer(
                    remoteVersion: comment.version,
                    remoteBuild: comment.build,
                    localVersion: localVersion,
                    localBuild: localBuild
                ) else {
                    throw UpdatePackageError.notNewer
                }
            }
            let digest = SHA256Util.hex(Data(SHA256.hash(data: dmg)))
            return VerifiedZip(
                directory: directory,
                dmgURL: dmgURL,
                comment: comment,
                zipName: zipName,
                dmgSHA256: digest
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The verified comment must name exactly the release the feed advertised.
    public static func checkMetadata(_ comment: TrustedUpdateComment, candidate: UpdateCandidate) throws {
        guard comment.version == candidate.version, comment.build == String(candidate.build) else {
            throw UpdatePackageError.metadataMismatch
        }
        if let listed = candidate.commit, listed.lowercased() != comment.commit {
            throw UpdatePackageError.metadataMismatch
        }
    }

    /// Signature first, then the trusted comment from the verified signature, then the checksum.
    public static func verifyPayload(
        dmg: Data,
        sha256File: Data,
        minisigText: String,
        encodedPublicKey: String,
        expectedFileName: String
    ) throws -> TrustedUpdateComment {
        let verified = try Minisign.verify(
            message: sha256File,
            signatureText: minisigText,
            encodedPublicKey: encodedPublicKey
        )
        guard let comment = TrustedUpdateComment.parse(verified.trustedComment) else {
            throw UpdatePackageError.commentRejected
        }
        if let file = comment.file, file != expectedFileName {
            throw UpdatePackageError.commentFileMismatch
        }
        guard let record = SHA256Util.parseChecksumRecord(String(data: sha256File, encoding: .utf8) ?? "") else {
            throw UpdatePackageError.checksumNameMismatch
        }
        guard record.fileName == expectedFileName else {
            throw UpdatePackageError.checksumNameMismatch
        }
        let actual = SHA256Util.hex(Data(SHA256.hash(data: dmg)))
        guard actual == record.hex else {
            throw UpdatePackageError.checksumMismatch
        }
        return comment
    }

    /// `ditto -x -k` into a fresh private folder. Run only after `UpdateZipInspector.inspect`.
    public static func extract(zip: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--norsrc", "--noextattr", "--noqtn", zip.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdatePackageError.extractFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdatePackageError.extractFailed }
    }

    public static func validateMembers(in directory: URL, allowed: Set<String>) throws -> [String: URL] {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        var found: [String: URL] = [:]
        for child in children {
            let name = child.lastPathComponent
            guard allowed.contains(name) else { throw UpdatePackageError.unexpectedEntry(name) }
            try assertRegularFile(child)
            found[name] = child
        }
        guard found.count == allowed.count else { throw UpdatePackageError.missingMember }
        return found
    }

    public static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard url.path.withCString({ chmod($0, 0o700) }) == 0 else {
            throw UpdatePackageError.extractFailed
        }
    }

    /// The bytes on disk must not be larger than the size the central directory declared.
    public static func enforceExtractedSizes(_ members: [String: URL], declared: [ZipEntryInfo]) throws {
        var total: UInt64 = 0
        for entry in declared {
            guard let url = members[entry.name] else { throw UpdatePackageError.missingMember }
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0 else {
                throw UpdatePackageError.notRegularFile
            }
            if info.st_size < 0 {
                throw UpdatePackageError.tooLarge
            }
            let size = UInt64(info.st_size)
            if size > UInt64(entry.uncompressedSize) || size > UpdateZipInspector.maxTotalUncompressed {
                throw UpdatePackageError.tooLarge
            }
            if total > UpdateZipInspector.maxTotalUncompressed - size {
                throw UpdatePackageError.tooLarge
            }
            total += size
        }
    }

    /// Re-read a file and compare it to a digest already checked against the signature.
    public static func fileMatchesDigest(_ url: URL, hex expected: String) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return SHA256Util.hex(Data(SHA256.hash(data: data))) == expected
    }

    public static func assertRegularFile(_ url: URL) throws {
        var info = stat()
        let rc = url.path.withCString { lstat($0, &info) }
        guard rc == 0 else { throw UpdatePackageError.notRegularFile }
        let mode = mode_t(info.st_mode)
        if (mode & S_IFMT) == S_IFLNK {
            throw UpdatePackageError.symlinkRejected
        }
        if (mode & S_IFMT) != S_IFREG {
            throw UpdatePackageError.notRegularFile
        }
    }
}
