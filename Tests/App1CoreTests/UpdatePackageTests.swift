// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import App1Core

final class UpdatePackageTests: XCTestCase {
    private let commit = String(repeating: "d", count: 40)
    private let basename = "WyvernBrowser"

    private struct Release {
        var zip: URL
        var key: String
        var comment: TrustedUpdateComment
        var candidate: UpdateCandidate
    }

    func testZipName() {
        let parsed = UpdateZipName.parse(fileName: "WyvernBrowser-0.1.0-b12.zip", basename: basename)
        XCTAssertEqual(parsed?.version, "0.1.0")
        XCTAssertEqual(parsed?.build, 12)
        XCTAssertEqual(parsed?.dmgName, "WyvernBrowser-0.1.0.dmg")
        XCTAssertNil(UpdateZipName.parse(fileName: "WyvernBrowser-0.1.0.zip", basename: basename))
        XCTAssertNil(UpdateZipName.parse(fileName: "WyvernBrowser-0.1.0-b02.zip", basename: basename))
        XCTAssertNil(UpdateZipName.parse(fileName: "Other-0.1.0-b1.zip", basename: basename))
        XCTAssertNil(UpdateZipName.parse(fileName: "WyvernBrowser-../x-b1.zip", basename: basename))
        XCTAssertNil(UpdateZipName.parse(fileName: "WyvernBrowser-0.1.0-b1.zip", basename: ""))
    }

    func testCommentFileAndBuildRules() throws {
        let key = Curve25519.Signing.PrivateKey()
        let dmgName = "WyvernBrowser-0.2.0.dmg"
        let dmg = Data("payload".utf8)
        let digest = SHA256Util.hex(Data(SHA256.hash(data: dmg)))
        let sha = Data("\(digest)  \(dmgName)\n".utf8)
        let encoded = Minisign.encodePublicKey(raw: key.publicKey.rawRepresentation)
        let line = "wyvern version=0.2.0 build=4 commit=\(commit) file=\(dmgName)"
        let sig = try Minisign.sign(message: sha, privateKey: key, trustedComment: line)
        let ok = try UpdatePackage.verifyPayload(
            dmg: dmg,
            sha256File: sha,
            minisigText: sig,
            encodedPublicKey: encoded,
            expectedFileName: dmgName
        )
        XCTAssertEqual(ok.build, "4")
        XCTAssertThrowsError(
            try UpdatePackage.verifyPayload(
                dmg: dmg,
                sha256File: sha,
                minisigText: sig,
                encodedPublicKey: encoded,
                expectedFileName: "WyvernBrowser-0.1.0.dmg"
            )
        ) { error in
            XCTAssertEqual(error as? UpdatePackageError, .commentFileMismatch)
        }
    }

    func testSignedMetadataMustMatchFeed() throws {
        let zipName = try XCTUnwrap(UpdateZipName.parse(fileName: "WyvernBrowser-0.2.0-b4.zip", basename: basename))
        let url = URL(string: "https://example.invalid/WyvernBrowser-0.2.0-b4.zip")!
        let comment = TrustedUpdateComment(version: "0.2.0", build: "4", commit: commit, file: zipName.dmgName)
        let listed = UpdateCandidate(version: "0.2.0", build: 4, commit: commit, zipURL: url, zipName: zipName)
        XCTAssertNoThrow(try UpdatePackage.checkMetadata(comment, candidate: listed))
        var unlisted = listed
        unlisted.commit = nil
        XCTAssertNoThrow(try UpdatePackage.checkMetadata(comment, candidate: unlisted))
        var otherCommit = listed
        otherCommit.commit = String(repeating: "0", count: 40)
        XCTAssertThrowsError(try UpdatePackage.checkMetadata(comment, candidate: otherCommit)) { error in
            XCTAssertEqual(error as? UpdatePackageError, .metadataMismatch)
        }
        var otherBuild = listed
        otherBuild.build = 5
        XCTAssertThrowsError(try UpdatePackage.checkMetadata(comment, candidate: otherBuild)) { error in
            XCTAssertEqual(error as? UpdatePackageError, .metadataMismatch)
        }
    }

    func testEmptyAndMisnamedZip() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("WyvernBrowser-0.1.0-b1.zip")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        XCTAssertThrowsError(try UpdatePackage.verifyZip(at: empty, encodedPublicKey: "x", basename: basename)) { error in
            XCTAssertEqual(error as? UpdatePackageError, .tooLarge)
        }
        let bad = dir.appendingPathComponent("notes.zip")
        FileManager.default.createFile(atPath: bad.path, contents: Data("zip".utf8))
        XCTAssertThrowsError(try UpdatePackage.verifyZip(at: bad, encodedPublicKey: "x", basename: basename)) { error in
            XCTAssertEqual(error as? UpdatePackageError, .badZipName)
        }
    }

    /// The traversal entry is refused by the inspector, before any extractor runs.
    func testTraversalZipRefusedBeforeExtraction() throws {
        let release = try makeRelease(version: "0.2.0", build: 3, entryName: { dmg, name in
            name == dmg + ".sha256.minisig" ? "../" + name : name
        })
        defer { try? FileManager.default.removeItem(at: release.zip.deletingLastPathComponent()) }
        XCTAssertThrowsError(
            try UpdatePackage.verifyZip(at: release.zip, encodedPublicKey: release.key, basename: basename)
        ) { error in
            XCTAssertEqual(error as? UpdatePackageError, .pathTraversal("../WyvernBrowser-0.2.0.dmg.sha256.minisig"))
        }
    }

    func testDittoZipRoundTrip() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto") else {
            throw XCTSkip("ditto is required to extract the synthetic zip")
        }
        let release = try makeRelease(version: "0.2.0", build: 3)
        defer { try? FileManager.default.removeItem(at: release.zip.deletingLastPathComponent()) }
        let verified = try UpdatePackage.verifyZip(
            at: release.zip,
            encodedPublicKey: release.key,
            basename: basename,
            localVersion: "0.1.0",
            localBuild: "9",
            candidate: release.candidate
        )
        try? FileManager.default.removeItem(at: verified.directory)
        XCTAssertEqual(verified.comment, release.comment)

        // Equal and older than the running app.
        for (version, build) in [("0.2.0", "3"), ("0.2.0", "4"), ("0.3.0", "1")] {
            XCTAssertThrowsError(
                try UpdatePackage.verifyZip(
                    at: release.zip,
                    encodedPublicKey: release.key,
                    basename: basename,
                    localVersion: version,
                    localBuild: build
                )
            ) { error in
                XCTAssertEqual(error as? UpdatePackageError, .notNewer)
            }
        }

        // A feed that names a different commit than the signature.
        var wrongCommit = release.candidate
        wrongCommit.commit = String(repeating: "f", count: 40)
        XCTAssertThrowsError(
            try UpdatePackage.verifyZip(at: release.zip, encodedPublicKey: release.key, basename: basename, candidate: wrongCommit)
        ) { error in
            XCTAssertEqual(error as? UpdatePackageError, .metadataMismatch)
        }

        // Wrong pinned key.
        let otherKey = Minisign.encodePublicKey(raw: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        XCTAssertThrowsError(
            try UpdatePackage.verifyZip(at: release.zip, encodedPublicKey: otherKey, basename: basename)
        ) { error in
            XCTAssertEqual(error as? MinisignError, .wrongKeyID)
        }

        // A renamed zip that claims a newer build.
        let renamed = release.zip.deletingLastPathComponent().appendingPathComponent("\(basename)-0.2.0-b4.zip")
        try FileManager.default.copyItem(at: release.zip, to: renamed)
        XCTAssertThrowsError(
            try UpdatePackage.verifyZip(at: renamed, encodedPublicKey: release.key, basename: basename)
        ) { error in
            XCTAssertEqual(error as? UpdatePackageError, .zipNameMismatch)
        }

        // A flipped image byte.
        let tampered = try makeRelease(version: "0.2.0", build: 3, flipDMG: true)
        defer { try? FileManager.default.removeItem(at: tampered.zip.deletingLastPathComponent()) }
        XCTAssertThrowsError(
            try UpdatePackage.verifyZip(at: tampered.zip, encodedPublicKey: tampered.key, basename: basename)
        ) { error in
            XCTAssertEqual(error as? UpdatePackageError, .checksumMismatch)
        }
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app1-zip-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A signed release zip built in memory. `entryName` may rename members; `flipDMG` changes
    /// one image byte after signing.
    private func makeRelease(
        version: String,
        build: Int,
        flipDMG: Bool = false,
        entryName: (String, String) -> String = { _, name in name }
    ) throws -> Release {
        let key = Curve25519.Signing.PrivateKey()
        let dmgName = "\(basename)-\(version).dmg"
        var dmg = Data("dmg-bytes-\(version)-\(build)".utf8)
        let digest = SHA256Util.hex(Data(SHA256.hash(data: dmg)))
        let sha = Data("\(digest)  \(dmgName)\n".utf8)
        let comment = TrustedUpdateComment(version: version, build: String(build), commit: commit, file: dmgName)
        let sig = try Minisign.sign(message: sha, privateKey: key, trustedComment: comment.line)
        if flipDMG {
            dmg[0] ^= 0x01
        }
        let entries = [
            TestZipEntry(entryName(dmgName, dmgName), dmg),
            TestZipEntry(entryName(dmgName, dmgName + ".sha256"), sha),
            TestZipEntry(entryName(dmgName, dmgName + ".sha256.minisig"), Data(sig.utf8))
        ]
        let dir = try scratch()
        let zipFileName = "\(basename)-\(version)-b\(build).zip"
        let zip = dir.appendingPathComponent(zipFileName)
        try TestZip.build(entries).write(to: zip)
        let zipName = try XCTUnwrap(UpdateZipName.parse(fileName: zipFileName, basename: basename))
        let candidate = UpdateCandidate(
            version: version,
            build: build,
            commit: commit,
            zipURL: URL(string: "https://example.invalid/\(zipFileName)")!,
            zipName: zipName
        )
        return Release(
            zip: zip,
            key: Minisign.encodePublicKey(raw: key.publicKey.rawRepresentation),
            comment: comment,
            candidate: candidate
        )
    }
}
