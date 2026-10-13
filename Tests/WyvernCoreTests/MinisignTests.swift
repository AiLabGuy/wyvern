// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import WyvernCore

final class MinisignTests: XCTestCase {
    func testValidSignature() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let message = Data("abc  def\n".utf8)
        let encoded = Minisign.encodePublicKey(raw: privateKey.publicKey.rawRepresentation)
        let text = try Minisign.sign(message: message, privateKey: privateKey, trustedComment: "timestamp:1")
        XCTAssertNoThrow(try Minisign.verify(message: message, signatureText: text, encodedPublicKey: encoded))
    }

    func testTamperedMessageRejected() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let message = Data("hello\n".utf8)
        let encoded = Minisign.encodePublicKey(raw: privateKey.publicKey.rawRepresentation)
        let text = try Minisign.sign(message: message, privateKey: privateKey, trustedComment: "t")
        XCTAssertThrowsError(
            try Minisign.verify(message: Data("HELLO\n".utf8), signatureText: text, encodedPublicKey: encoded)
        )
    }

    func testWrongKeyIDRejected() throws {
        let a = Curve25519.Signing.PrivateKey()
        let b = Curve25519.Signing.PrivateKey()
        let message = Data("x".utf8)
        let text = try Minisign.sign(message: message, privateKey: a, trustedComment: "t")
        var other = Minisign.PublicKey(
            keyID: Data(repeating: 9, count: 8),
            raw: b.publicKey.rawRepresentation
        )
        other = Minisign.PublicKey(keyID: Data(repeating: 1, count: 8), raw: a.publicKey.rawRepresentation)
        XCTAssertThrowsError(
            try Minisign.verify(message: message, signatureText: text, encodedPublicKey: other.encoded)
        ) { error in
            XCTAssertEqual(error as? MinisignError, .wrongKeyID)
        }
    }

    func testWrongKeyRejected() throws {
        let a = Curve25519.Signing.PrivateKey()
        let b = Curve25519.Signing.PrivateKey()
        let message = Data("x".utf8)
        let text = try Minisign.sign(message: message, privateKey: a, trustedComment: "t")
        let encoded = Minisign.encodePublicKey(raw: b.publicKey.rawRepresentation)
        XCTAssertThrowsError(
            try Minisign.verify(message: message, signatureText: text, encodedPublicKey: encoded)
        )
    }

    func testMalformedAndEmptyKeyRefused() {
        XCTAssertThrowsError(try Minisign.verify(message: Data(), signatureText: "nope", encodedPublicKey: "AAAA"))
        XCTAssertThrowsError(try Minisign.verify(message: Data(), signatureText: "", encodedPublicKey: "")) { error in
            XCTAssertEqual(error as? MinisignError, .emptyKey)
        }
    }

    func testVerifyDownloadHappyPathAndMismatch() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let dmg = Data("dmg-bytes".utf8)
        let dmgName = "app.dmg"
        let digest = SHA256Util.hex(Data(SHA256.hash(data: dmg)))
        let shaFile = Data("\(digest)  \(dmgName)\n".utf8)
        let encoded = Minisign.encodePublicKey(raw: privateKey.publicKey.rawRepresentation)
        let commit = String(repeating: "a", count: 40)
        let comment = "wyvern version=0.2.0 build=2 commit=\(commit) file=\(dmgName)"
        let sig = try Minisign.sign(message: shaFile, privateKey: privateKey, trustedComment: comment)
        let parsed = try UpdatePackage.verifyPayload(
            dmg: dmg,
            sha256File: shaFile,
            minisigText: sig,
            encodedPublicKey: encoded,
            expectedFileName: dmgName
        )
        XCTAssertEqual(parsed.file, dmgName)
        XCTAssertEqual(parsed.build, "2")
        XCTAssertThrowsError(
            try UpdatePackage.verifyPayload(
                dmg: Data("other".utf8),
                sha256File: shaFile,
                minisigText: sig,
                encodedPublicKey: encoded,
                expectedFileName: dmgName
            )
        ) { error in
            XCTAssertEqual(error as? UpdatePackageError, .checksumMismatch)
        }
        XCTAssertThrowsError(
            try UpdatePackage.verifyPayload(
                dmg: dmg,
                sha256File: shaFile,
                minisigText: sig,
                encodedPublicKey: "",
                expectedFileName: dmgName
            )
        ) { error in
            XCTAssertEqual(error as? MinisignError, .emptyKey)
        }
        XCTAssertThrowsError(
            try UpdatePackage.verifyPayload(
                dmg: dmg,
                sha256File: shaFile,
                minisigText: sig,
                encodedPublicKey: encoded,
                expectedFileName: "other.dmg"
            )
        ) { error in
            XCTAssertEqual(error as? UpdatePackageError, .commentFileMismatch)
        }
    }

    /// The release-path rules in one place: no signature, a different key, or a changed
    /// checksum file are each refused before any checksum or install step trusts the payload.
    func testUnsignedTamperedAndWrongKeyPayloadsRefused() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let stranger = Curve25519.Signing.PrivateKey()
        let dmgName = "WyvernBrowser-0.2.0.dmg"
        let dmg = Data("dmg-bytes".utf8)
        let digest = SHA256Util.hex(Data(SHA256.hash(data: dmg)))
        let shaFile = Data("\(digest)  \(dmgName)\n".utf8)
        let commit = String(repeating: "e", count: 40)
        let comment = "wyvern version=0.2.0 build=2 commit=\(commit) file=\(dmgName)"
        let pinned = Minisign.encodePublicKey(raw: signer.publicKey.rawRepresentation)
        let good = try Minisign.sign(message: shaFile, privateKey: signer, trustedComment: comment)
        XCTAssertNoThrow(try UpdatePackage.verifyPayload(
            dmg: dmg, sha256File: shaFile, minisigText: good, encodedPublicKey: pinned, expectedFileName: dmgName
        ))
        // Unsigned: no signature file content at all.
        XCTAssertThrowsError(try UpdatePackage.verifyPayload(
            dmg: dmg, sha256File: shaFile, minisigText: "", encodedPublicKey: pinned, expectedFileName: dmgName
        )) { error in
            XCTAssertEqual(error as? MinisignError, .malformed)
        }
        // Signed by another key: its key id does not match the pinned key.
        let foreign = try Minisign.sign(message: shaFile, privateKey: stranger, trustedComment: comment)
        XCTAssertThrowsError(try UpdatePackage.verifyPayload(
            dmg: dmg, sha256File: shaFile, minisigText: foreign, encodedPublicKey: pinned, expectedFileName: dmgName
        )) { error in
            XCTAssertEqual(error as? MinisignError, .wrongKeyID)
        }
        // Another key's signature relabelled with the pinned key id still fails the curve check.
        var relabelled = foreign.split(whereSeparator: \.isNewline).map(String.init)
        var blob = try XCTUnwrap(Data(base64Encoded: relabelled[1]))
        let pinnedID = try XCTUnwrap(Minisign.PublicKey.parse(pinned)).keyID
        blob.replaceSubrange(2..<10, with: pinnedID)
        relabelled[1] = blob.base64EncodedString()
        XCTAssertThrowsError(try UpdatePackage.verifyPayload(
            dmg: dmg,
            sha256File: shaFile,
            minisigText: relabelled.joined(separator: "\n") + "\n",
            encodedPublicKey: pinned,
            expectedFileName: dmgName
        )) { error in
            XCTAssertEqual(error as? MinisignError, .invalidSignature)
        }
        // A checksum file rewritten to match a swapped image breaks the signature.
        let swapped = Data("evil-bytes".utf8)
        let swappedSha = Data("\(SHA256Util.hex(Data(SHA256.hash(data: swapped))))  \(dmgName)\n".utf8)
        XCTAssertThrowsError(try UpdatePackage.verifyPayload(
            dmg: swapped, sha256File: swappedSha, minisigText: good, encodedPublicKey: pinned, expectedFileName: dmgName
        )) { error in
            XCTAssertEqual(error as? MinisignError, .invalidSignature)
        }
        // A swapped image with the original checksum file fails the checksum.
        XCTAssertThrowsError(try UpdatePackage.verifyPayload(
            dmg: swapped, sha256File: shaFile, minisigText: good, encodedPublicKey: pinned, expectedFileName: dmgName
        )) { error in
            XCTAssertEqual(error as? UpdatePackageError, .checksumMismatch)
        }
    }

    func testStrictPublicKeyParsing() throws {
        let key = Curve25519.Signing.PrivateKey()
        let encoded = Minisign.encodePublicKey(raw: key.publicKey.rawRepresentation)
        XCTAssertEqual(encoded.count, Minisign.encodedLength)
        XCTAssertTrue(encoded.hasPrefix("RW"))
        XCTAssertNotNil(Minisign.PublicKey.parse(encoded))
        XCTAssertNil(Minisign.PublicKey.parse(encoded + "=="))
        XCTAssertNil(Minisign.PublicKey.parse(String(encoded.dropFirst())))
        let parsed = try XCTUnwrap(Minisign.PublicKey.parse(encoded))
        XCTAssertEqual(parsed.fingerprint.count, 16)
    }

    func testPrehashedEDIsRefused() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let message = Data("abc".utf8)
        let encoded = Minisign.encodePublicKey(raw: privateKey.publicKey.rawRepresentation)
        let text = try Minisign.sign(message: message, privateKey: privateKey, trustedComment: "t")
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var blob = try XCTUnwrap(Data(base64Encoded: lines[1]))
        blob[0] = 0x45
        blob[1] = 0x44
        lines[1] = blob.base64EncodedString()
        let tampered = lines.joined(separator: "\n") + "\n"
        let expected = "prehashed ED signatures are refused; sign with minisign -l (legacy Ed)"
        XCTAssertThrowsError(try Minisign.parseSignature(tampered)) { error in
            XCTAssertEqual(error as? MinisignError, .prehashedRefused)
            XCTAssertEqual(String(describing: error), expected)
        }
        XCTAssertThrowsError(
            try Minisign.verify(message: message, signatureText: tampered, encodedPublicKey: encoded)
        ) { error in
            XCTAssertEqual(error as? MinisignError, .prehashedRefused)
            XCTAssertEqual(String(describing: error), expected)
        }
    }

    func testTrustedCommentKeepsTrailingSpaces() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let message = Data("abc\n".utf8)
        let encoded = Minisign.encodePublicKey(raw: privateKey.publicKey.rawRepresentation)
        let commit = String(repeating: "b", count: 40)
        let comment = "wyvern version=0.1.0 build=1 commit=\(commit) file=app.dmg   "
        let text = try Minisign.sign(message: message, privateKey: privateKey, trustedComment: comment)
        let parsed = try Minisign.parseSignature(text)
        XCTAssertEqual(parsed.trustedComment, comment)
        XCTAssertNil(TrustedUpdateComment.parse(parsed.trustedComment))
        XCTAssertNoThrow(try Minisign.verify(message: message, signatureText: text, encodedPublicKey: encoded))
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        lines[2] = "trusted comment: " + comment.trimmingCharacters(in: .whitespaces)
        let stripped = lines.joined(separator: "\n") + "\n"
        XCTAssertThrowsError(
            try Minisign.verify(message: message, signatureText: stripped, encodedPublicKey: encoded)
        ) { error in
            XCTAssertEqual(error as? MinisignError, .invalidSignature)
        }
    }

    func testUnsignedTrustedCommentTamperIsRefused() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let dmg = Data("dmg-bytes".utf8)
        let dmgName = "app.dmg"
        let digest = SHA256Util.hex(Data(SHA256.hash(data: dmg)))
        let shaFile = Data("\(digest)  \(dmgName)\n".utf8)
        let encoded = Minisign.encodePublicKey(raw: privateKey.publicKey.rawRepresentation)
        let commit = String(repeating: "c", count: 40)
        let comment = "wyvern version=0.2.0 build=2 commit=\(commit) file=\(dmgName)"
        let sig = try Minisign.sign(message: shaFile, privateKey: privateKey, trustedComment: comment)
        var lines = sig.split(whereSeparator: \.isNewline).map(String.init)
        lines[2] = lines[2].replacingOccurrences(of: "version=0.2.0", with: "version=9.9.9")
        let tampered = lines.joined(separator: "\n") + "\n"
        XCTAssertThrowsError(
            try UpdatePackage.verifyPayload(
                dmg: dmg,
                sha256File: shaFile,
                minisigText: tampered,
                encodedPublicKey: encoded,
                expectedFileName: dmgName
            )
        ) { error in
            XCTAssertEqual(error as? MinisignError, .invalidSignature)
        }
    }
}
