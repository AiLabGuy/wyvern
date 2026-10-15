// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import WyvernCore

private final class MemoryDefaults: UpdateSourceDefaults {
    var values: [String: Any] = [:]

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

final class UpdateSourceTests: XCTestCase {
    /// A test-only minisign public key (its secret key was discarded), and its key ID as minisign prints it.
    private let shippedKey = "RWSIjnyLX8sf7A3Bq7xOci/VQVXTxuKrlcZiD15owL38y0EEbKINt/jH"
    private let shippedKeyID = "EC1FCB5F8B7C8E88"
    private let builtInURL = "https://updates.example.invalid/wyvern/latest.json"

    private func freshKey() -> String {
        Minisign.encodePublicKey(raw: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
    }

    private func store(_ defaults: MemoryDefaults, builtIn: String? = nil, compiled: Bool = false) -> UpdateSourceStore {
        UpdateSourceStore(
            defaults: defaults,
            info: ["WyvernUpdateFeedURL": builtIn ?? builtInURL, "WyvernUpdatePublicKey": shippedKey],
            isDevUpdaterCompiled: compiled
        )
    }

    func testKeyFingerprintMatchesMinisignKeyID() throws {
        let key = try XCTUnwrap(Minisign.PublicKey.parse(shippedKey))
        XCTAssertEqual(key.fingerprint, shippedKeyID)
        XCTAssertEqual(key.encoded, shippedKey)
    }

    func testKeyValidation() {
        XCTAssertEqual(UpdateSourceValidator.parseKey(""), .failure(.missingKey))
        XCTAssertEqual(UpdateSourceValidator.parseKey("  \n "), .failure(.missingKey))
        XCTAssertEqual(UpdateSourceValidator.parseKey("RWQ"), .failure(.malformedKey))
        XCTAssertEqual(UpdateSourceValidator.parseKey(String(shippedKey.dropLast())), .failure(.malformedKey))
        XCTAssertEqual(UpdateSourceValidator.parseKey(shippedKey + "A"), .failure(.malformedKey))
        // Correct length, but the "ED" (prehashed) algorithm bytes instead of legacy "Ed".
        var prehashed = [UInt8](Data(base64Encoded: shippedKey)!)
        prehashed[1] = 0x44
        XCTAssertEqual(UpdateSourceValidator.parseKey(Data(prehashed).base64EncodedString()), .failure(.malformedKey))
        // All-zero key id.
        var zeroID = [UInt8](Data(base64Encoded: shippedKey)!)
        for index in 2..<10 {
            zeroID[index] = 0
        }
        XCTAssertEqual(UpdateSourceValidator.parseKey(Data(zeroID).base64EncodedString()), .failure(.malformedKey))
        // A whole minisign .pub file is accepted.
        let pub = "untrusted comment: minisign public key \(shippedKeyID)\n\(shippedKey)\n"
        XCTAssertEqual(try? UpdateSourceValidator.parseKey(pub).get().encoded, shippedKey)
    }

    func testUserSourceWithoutKeyRejectedAndNotStored() {
        let defaults = MemoryDefaults()
        let sources = store(defaults)
        let result = sources.saveCustom(urlText: "https://fork.example.invalid/latest.json", keyText: "")
        XCTAssertEqual(result.map(\.feedURL), .failure(.missingKey))
        XCTAssertTrue(defaults.values.isEmpty)
        XCTAssertFalse(sources.hasCustomSource)
        let malformed = sources.saveCustom(urlText: "https://fork.example.invalid/latest.json", keyText: "RWQnotakey")
        XCTAssertEqual(malformed.map(\.feedURL), .failure(.malformedKey))
        XCTAssertTrue(defaults.values.isEmpty)
    }

    func testHTTPSourceRejectedInRelease() {
        let defaults = MemoryDefaults()
        let sources = store(defaults, compiled: false)
        let result = sources.saveCustom(urlText: "http://192.168.1.8/latest.json", keyText: freshKey())
        XCTAssertEqual(result.map(\.feedURL), .failure(.httpRejected))
        XCTAssertTrue(defaults.values.isEmpty)
        #if !WYVERN_DEV_UPDATER
        // Without the compile flag, no caller-supplied switch re-enables HTTP.
        XCTAssertEqual(
            UpdateTransportPolicy.parseSourceURL("http://10.0.0.2/latest.json", allowsDevHTTP: true).map(\.absoluteString),
            .failure(.httpRejected)
        )
        XCTAssertEqual(
            UpdateTransportPolicy.parseSourceURL(
                "http://10.0.0.2:8080/wyvern-dev/latest.json",
                allowsDevHTTP: true
            ).map(\.absoluteString),
            .failure(.httpRejected)
        )
        let devStore = store(MemoryDefaults(), compiled: true)
        XCTAssertEqual(
            devStore.saveCustom(urlText: "http://10.0.0.2/latest.json", keyText: freshKey()).map(\.feedURL),
            .failure(.httpRejected)
        )
        #endif
    }

    func testURLValidation() {
        let key = freshKey()
        func check(_ url: String) -> UpdateSourceError? {
            if case .failure(let error) = UpdateSourceValidator.validate(urlText: url, keyText: key, origin: .custom, allowsDevHTTP: false) {
                return error
            }
            return nil
        }
        XCTAssertNil(check("https://fork.example.invalid/latest.json"))
        XCTAssertEqual(check(""), .emptyURL)
        XCTAssertEqual(check("fork.example.invalid/latest.json"), .malformedURL)
        XCTAssertEqual(check("ftp://fork.example.invalid/latest.json"), .malformedURL)
        XCTAssertEqual(check("file:///tmp/latest.json"), .malformedURL)
        XCTAssertEqual(check("https://user:secret@fork.example.invalid/latest.json"), .credentialsInURL)
        XCTAssertEqual(check("https://fork.example.invalid/a b.json"), .malformedURL)
    }

    func testSaveResetAndFingerprint() throws {
        let defaults = MemoryDefaults()
        let sources = store(defaults)
        let key = freshKey()
        let saved = try sources.saveCustom(urlText: " https://fork.example.invalid/latest.json ", keyText: key).get()
        XCTAssertEqual(saved.origin, .custom)
        XCTAssertEqual(saved.feedURL.absoluteString, "https://fork.example.invalid/latest.json")
        XCTAssertEqual(saved.keyFingerprint.count, 16)
        let current = try sources.current().get()
        XCTAssertEqual(current, saved)
        sources.resetToDefault()
        XCTAssertFalse(sources.hasCustomSource)
        let restored = try sources.current().get()
        XCTAssertEqual(restored.origin, .builtIn)
        XCTAssertEqual(restored.feedURL.absoluteString, builtInURL)
        XCTAssertEqual(restored.keyFingerprint, shippedKeyID)
    }

    func testSavingBuiltInValuesClearsCustomEntry() throws {
        let defaults = MemoryDefaults()
        let sources = store(defaults)
        let result = try sources.saveCustom(urlText: builtInURL, keyText: shippedKey).get()
        XCTAssertEqual(result.origin, .builtIn)
        XCTAssertFalse(sources.hasCustomSource)
    }

    /// A stored URL whose key was removed or damaged is an error, never a silent fallback.
    func testDamagedStoredSourceIsNotUsed() {
        let defaults = MemoryDefaults()
        defaults.values[UpdateSourceStore.customURLKey] = "https://fork.example.invalid/latest.json"
        let sources = store(defaults)
        XCTAssertTrue(sources.hasCustomSource)
        XCTAssertEqual(sources.current().map(\.feedURL), .failure(.missingKey))
        defaults.values[UpdateSourceStore.customKeyKey] = "RWQdamaged"
        XCTAssertEqual(sources.current().map(\.feedURL), .failure(.malformedKey))
    }

    func testBuiltInNotConfigured() {
        let sources = store(MemoryDefaults(), builtIn: "")
        XCTAssertEqual(sources.builtIn().map(\.feedURL), .failure(.notConfigured))
    }

    func testPrivateHostClassification() {
        XCTAssertTrue(UpdateTransportPolicy.isPrivateNetworkHost("10.0.0.1"))
        XCTAssertTrue(UpdateTransportPolicy.isPrivateNetworkHost("192.168.0.1"))
        XCTAssertTrue(UpdateTransportPolicy.isPrivateNetworkHost("172.16.0.1"))
        XCTAssertTrue(UpdateTransportPolicy.isPrivateNetworkHost("172.31.255.1"))
        XCTAssertFalse(UpdateTransportPolicy.isPrivateNetworkHost("172.15.0.1"))
        XCTAssertFalse(UpdateTransportPolicy.isPrivateNetworkHost("8.8.8.8"))
        XCTAssertFalse(UpdateTransportPolicy.isPrivateNetworkHost("example.invalid"))
        XCTAssertFalse(UpdateTransportPolicy.isPrivateNetworkHost("10.0.0.1.example.invalid"))
        XCTAssertFalse(UpdateTransportPolicy.isPrivateNetworkHost("10.0.0.256"))
        XCTAssertFalse(UpdateTransportPolicy.isPrivateNetworkHost("10.0.0"))
    }

    #if WYVERN_DEV_UPDATER
    func testDevBuildAllowsPrivateHTTPOnly() throws {
        let sources = store(MemoryDefaults(), compiled: true)
        let ok = try sources.saveCustom(urlText: "http://10.0.0.2/latest.json", keyText: freshKey()).get()
        XCTAssertTrue(ok.allowsDevHTTP)
        XCTAssertEqual(
            sources.saveCustom(urlText: "http://8.8.8.8/latest.json", keyText: freshKey()).map(\.feedURL),
            .failure(.publicHTTPRejected)
        )
    }

    func testBuiltInDevSourceAcceptsPrivateLANHTTP() throws {
        let lan = "http://10.0.0.2:8080/wyvern-dev/latest.json"
        let sources = UpdateSourceStore(
            defaults: MemoryDefaults(),
            info: [
                "WyvernUpdateFeedURL": lan,
                "WyvernUpdatePublicKey": shippedKey,
                "WyvernUpdateDevSource": "1"
            ],
            isDevUpdaterCompiled: true
        )
        let source = try sources.builtIn().get()
        XCTAssertTrue(source.allowsDevHTTP)
        XCTAssertEqual(source.feedURL.host, "10.0.0.2")
        XCTAssertEqual(source.feedURL.absoluteString, lan)
    }
    #endif

    func testPlainLanguageMessages() {
        XCTAssertTrue(UpdateUserMessage.text(for: UpdateSourceError.missingKey).contains("never used without its key"))
        XCTAssertTrue(UpdateUserMessage.text(for: UpdateSourceError.httpRejected).contains("HTTPS"))
        XCTAssertTrue(UpdateUserMessage.text(for: MinisignError.invalidSignature).contains("Nothing was installed"))
        XCTAssertTrue(UpdateUserMessage.text(for: UpdatePackageError.notNewer).contains("not newer"))
        XCTAssertTrue(UpdateUserMessage.text(for: UpdatePackageError.pathTraversal("../x")).contains("Nothing was installed"))
    }
}
