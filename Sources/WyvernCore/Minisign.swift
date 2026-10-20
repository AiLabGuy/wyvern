// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public enum MinisignError: Error, Equatable, Sendable {
    case emptyKey
    case malformed
    case wrongKeyID
    case invalidSignature
    /// Prehashed "ED" (bytes 0x45 0x44). Stock minisign produces legacy "Ed" only with `-l`.
    case prehashedRefused
}

extension MinisignError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .emptyKey:
            return "empty public key"
        case .malformed:
            return "malformed signature"
        case .wrongKeyID:
            return "wrong key id"
        case .invalidSignature:
            return "invalid signature"
        case .prehashedRefused:
            return "prehashed ED signatures are refused; sign with minisign -l (legacy Ed)"
        }
    }
}

/// minisign-compatible legacy Ed25519 ("Ed", bytes 0x45 0x64) over the raw bytes of a `.sha256` file.
/// Prehashed "ED" is refused. Stock `minisign -V` verifies this legacy form.
/// Stock `minisign` must be given `-l` to sign in this form.
public enum Minisign {
    public static let algorithm: [UInt8] = [0x45, 0x64] // "Ed"
    /// Exact trusted-comment prefix minisign writes. One space, this case.
    public static let trustedCommentPrefix = "trusted comment: "
    /// Base64 length of an encoded public key (2 algorithm + 8 id + 32 key bytes).
    public static let encodedLength = 56

    public struct PublicKey: Equatable, Sendable {
        public var keyID: Data
        public var raw: Data

        public init(keyID: Data, raw: Data) {
            self.keyID = keyID
            self.raw = raw
        }

        public var encoded: String {
            var blob = Data(algorithm)
            blob.append(keyID)
            blob.append(raw)
            return blob.base64EncodedString()
        }

        /// Key id as minisign prints it: the 8 id bytes read as a little-endian integer, 16 hex digits.
        public var fingerprint: String {
            keyID.reversed().map { String(format: "%02X", $0) }.joined()
        }

        /// Canonical base64 only: 56 characters, 42 bytes, legacy "Ed", a non-zero key id.
        public static func parse(_ text: String) -> PublicKey? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count == encodedLength,
                  let data = Data(base64Encoded: trimmed),
                  data.count == 42,
                  data.base64EncodedString() == trimmed else {
                return nil
            }
            let bytes = [UInt8](data)
            guard bytes[0] == 0x45, bytes[1] == 0x64 else { return nil }
            let id = Data(bytes[2..<10])
            guard id.contains(where: { $0 != 0 }) else { return nil }
            let raw = Data(bytes[10..<42])
            guard (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else { return nil }
            return PublicKey(keyID: id, raw: raw)
        }
    }

    public struct SignatureFile: Equatable, Sendable {
        public var untrustedComment: String
        public var keyID: Data
        public var signature: Data
        public var trustedComment: String
        public var globalSignature: Data
    }

    public static func keyID(forPublicKey raw: Data) -> Data {
        let digest = SHA256.hash(data: raw)
        return Data(digest.prefix(8))
    }

    public static func encodePublicKey(raw: Data) -> String {
        PublicKey(keyID: keyID(forPublicKey: raw), raw: raw).encoded
    }

    public static func signedText(message: Data, signer: Curve25519.Signing.PrivateKey, comment: String) throws -> String {
        try sign(message: message, privateKey: signer, trustedComment: comment)
    }

    public static func sign(message: Data, privateKey: Curve25519.Signing.PrivateKey, trustedComment: String) throws -> String {
        let signature = try privateKey.signature(for: message)
        let publicRaw = privateKey.publicKey.rawRepresentation
        let id = keyID(forPublicKey: publicRaw)
        var blob = Data(algorithm)
        blob.append(id)
        blob.append(signature)
        let trusted = trustedComment
        var globalMessage = Data(signature)
        globalMessage.append(Data(trusted.utf8))
        let global = try privateKey.signature(for: globalMessage)
        var lines: [String] = []
        lines.append("untrusted comment: signature from wyvern-update-signing")
        lines.append(blob.base64EncodedString())
        lines.append("trusted comment: \(trusted)")
        lines.append(global.base64EncodedString())
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parseSignature(_ text: String) throws -> SignatureFile {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }
        guard lines.count >= 4 else { throw MinisignError.malformed }
        let untrusted = lines[0]
        guard untrusted.lowercased().hasPrefix("untrusted comment:") else { throw MinisignError.malformed }
        guard let blob = Data(base64Encoded: lines[1]), blob.count == 74 else { throw MinisignError.malformed }
        let bytes = [UInt8](blob)
        if bytes[0] == 0x45, bytes[1] == 0x44 {
            throw MinisignError.prehashedRefused
        }
        guard bytes[0] == 0x45, bytes[1] == 0x64 else { throw MinisignError.malformed }
        let keyID = Data(bytes[2..<10])
        let signature = Data(bytes[10..<74])
        let trustedLine = lines[2]
        guard trustedLine.hasPrefix(trustedCommentPrefix) else { throw MinisignError.malformed }
        // Drop only the prefix. Do not trim: minisign signs the comment bytes after the
        // single trailing newline that `split` already removed.
        let trusted = String(trustedLine.dropFirst(trustedCommentPrefix.count))
        guard let global = Data(base64Encoded: lines[3]), global.count == 64 else { throw MinisignError.malformed }
        return SignatureFile(
            untrustedComment: untrusted,
            keyID: keyID,
            signature: signature,
            trustedComment: trusted,
            globalSignature: global
        )
    }

    /// Returns the signature file whose signature and trusted comment were both checked.
    /// Callers read the trusted comment only from this return value.
    @discardableResult
    public static func verify(message: Data, signatureText: String, encodedPublicKey: String) throws -> SignatureFile {
        let trimmed = encodedPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MinisignError.emptyKey }
        guard let key = PublicKey.parse(trimmed) else { throw MinisignError.malformed }
        let file = try parseSignature(signatureText)
        if file.keyID != key.keyID {
            throw MinisignError.wrongKeyID
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.raw)
        } catch {
            throw MinisignError.malformed
        }
        guard publicKey.isValidSignature(file.signature, for: message) else {
            throw MinisignError.invalidSignature
        }
        var globalMessage = Data(file.signature)
        globalMessage.append(Data(file.trustedComment.utf8))
        guard publicKey.isValidSignature(file.globalSignature, for: globalMessage) else {
            throw MinisignError.invalidSignature
        }
        return file
    }
}
