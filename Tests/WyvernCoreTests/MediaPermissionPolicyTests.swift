// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class MediaPermissionPolicyTests: XCTestCase {
    func testOriginNormalization() {
        XCTAssertEqual(
            MediaPermissionPolicy.originKey(scheme: "HTTPS", host: "Example.COM", port: 443),
            "https://example.com"
        )
        XCTAssertEqual(
            MediaPermissionPolicy.originKey(scheme: "http", host: "localhost", port: 0),
            "http://localhost"
        )
        XCTAssertEqual(
            MediaPermissionPolicy.originKey(scheme: "http", host: "127.0.0.1", port: 8080),
            "http://127.0.0.1:8080"
        )
        XCTAssertEqual(
            MediaPermissionPolicy.originKey(scheme: "https", host: "example.com", port: 8443),
            "https://example.com:8443"
        )
    }

    func testInsecureOriginDeniedWithoutPrompt() {
        XCTAssertFalse(MediaPermissionPolicy.isEligibleOrigin("http://example.com"))
        XCTAssertFalse(MediaPermissionPolicy.isEligibleOrigin("file://localhost"))
        XCTAssertFalse(MediaPermissionPolicy.isEligibleOrigin("http://192.168.1.5"))
        XCTAssertEqual(
            MediaPermissionPolicy.evaluate(
                originKey: "http://example.com",
                kind: .microphone,
                stored: .alwaysAllow
            ),
            .deny
        )
    }

    func testEligibleOrigins() {
        XCTAssertTrue(MediaPermissionPolicy.isEligibleOrigin("https://example.com"))
        XCTAssertTrue(MediaPermissionPolicy.isEligibleOrigin("http://localhost"))
        XCTAssertTrue(MediaPermissionPolicy.isEligibleOrigin("http://127.0.0.1:9"))
        XCTAssertEqual(
            MediaPermissionPolicy.evaluate(
                originKey: "https://example.com",
                kind: .microphone,
                stored: nil
            ),
            .prompt
        )
    }

    func testStoredAllowAndDeny() {
        XCTAssertEqual(
            MediaPermissionPolicy.evaluate(
                originKey: "https://example.com",
                kind: .camera,
                stored: .alwaysAllow
            ),
            .grant
        )
        XCTAssertEqual(
            MediaPermissionPolicy.evaluate(
                originKey: "https://example.com",
                kind: .camera,
                stored: .alwaysDeny
            ),
            .deny
        )
        let once = MediaPermissionPolicy.apply(.allowOnce)
        XCTAssertTrue(once.grant)
        XCTAssertNil(once.stored)
        let always = MediaPermissionPolicy.apply(.alwaysAllow)
        XCTAssertTrue(always.grant)
        XCTAssertEqual(always.stored, .alwaysAllow)
        let deny = MediaPermissionPolicy.apply(.deny)
        XCTAssertFalse(deny.grant)
        XCTAssertNil(deny.stored)
    }
}

final class MediaPermissionStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testRevokeAndPersistenceRoundTrip() throws {
        let store = MediaPermissionStore(directory: directory)
        store.set(.alwaysAllow, origin: "https://example.com", kind: .microphone)
        store.set(.alwaysDeny, origin: "https://example.com", kind: .camera)
        XCTAssertEqual(store.decision(origin: "https://example.com", kind: .microphone), .alwaysAllow)
        XCTAssertEqual(store.decision(origin: "https://example.com", kind: .camera), .alwaysDeny)
        store.revoke(origin: "https://example.com", kind: .camera)
        XCTAssertNil(store.decision(origin: "https://example.com", kind: .camera))
        XCTAssertEqual(store.entries.count, 1)

        let reloaded = MediaPermissionStore(directory: directory)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.decision(origin: "https://example.com", kind: .microphone), .alwaysAllow)

        store.removeAll()
        XCTAssertTrue(store.entries.isEmpty)
        let empty = MediaPermissionStore(directory: directory)
        XCTAssertTrue(empty.entries.isEmpty)
    }

    func testCorruptFileFallsBackToEmpty() throws {
        let file = directory.appendingPathComponent(AppInfo.mediaPermissionsFileName)
        try Data("{ not json".utf8).write(to: file)
        let store = MediaPermissionStore(directory: directory)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let quarantined = file.appendingPathExtension("corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path))
    }

    func testDisplayNameConstants() {
        XCTAssertEqual(AppInfo.displayName, "Wyvern")
        XCTAssertEqual(AppInfo.shortName, "Wyvern")
        XCTAssertEqual(AppInfo.productName, "Wyvern Browser")
        XCTAssertTrue(AppInfo.trademarkFootnote.contains(AppInfo.productName))
        XCTAssertEqual(AppInfo.marketingVersion, "0.1.0")
        XCTAssertEqual(AppInfo.fallbackBundleIdentifier, "com.example.wyvern")
        XCTAssertEqual(AppInfo.bundleIdentifier, AppInfo.fallbackBundleIdentifier)
    }
}
