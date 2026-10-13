// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class SitePermissionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-site-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testAllowBlockRoundTripAndAskIsNotStored() throws {
        let store = SitePermissionStore(directory: directory)
        store.set(.allow, origin: "https://example.com", kind: .popups)
        store.set(.block, origin: "https://example.com", kind: .autoplay)
        store.set(.ask, origin: "https://example.com", kind: .popups)
        XCTAssertNil(store.storedChoice(origin: "https://example.com", kind: .popups))
        XCTAssertEqual(store.choice(origin: "https://example.com", kind: .popups), .ask)
        XCTAssertEqual(store.storedChoice(origin: "https://example.com", kind: .autoplay), .block)

        let reloaded = SitePermissionStore(directory: directory)
        XCTAssertEqual(reloaded.origins, ["https://example.com"])
        XCTAssertEqual(reloaded.storedChoice(origin: "https://example.com", kind: .autoplay), .block)
        XCTAssertNil(reloaded.storedChoice(origin: "https://example.com", kind: .popups))
    }

    func testLocationAskStaysDistinctFromTheDeniedDefault() {
        let store = SitePermissionStore(directory: directory)
        XCTAssertNil(store.storedChoice(origin: "https://example.com", kind: .location))
        XCTAssertEqual(
            SitePermissionPolicy.displayedChoice(stored: nil, kind: .location),
            .block
        )
        XCTAssertEqual(
            SitePermissionPolicy.displayedChoice(stored: nil, kind: .notifications),
            .block
        )
        XCTAssertEqual(
            SitePermissionPolicy.displayedChoice(stored: nil, kind: .camera),
            .ask
        )
        store.set(.ask, origin: "https://example.com", kind: .location)
        XCTAssertEqual(store.storedChoice(origin: "https://example.com", kind: .location), .ask)
        XCTAssertEqual(
            SitePermissionPolicy.displayedChoice(
                stored: store.storedChoice(origin: "https://example.com", kind: .location),
                kind: .location
            ),
            .ask
        )
        let reloaded = SitePermissionStore(directory: directory)
        XCTAssertEqual(reloaded.storedChoice(origin: "https://example.com", kind: .location), .ask)
        XCTAssertFalse(SitePermissionPolicy.canApplyInWebKit(.location))
        XCTAssertFalse(SitePermissionPolicy.canApplyInWebKit(.notifications))
    }

    func testRemoveDropsOneOriginAndRemoveAllClearsTheFile() throws {
        let store = SitePermissionStore(directory: directory)
        store.set(.block, origin: "https://a.example", kind: .popups)
        store.set(.allow, origin: "https://b.example", kind: .autoplay)
        store.remove(origin: "https://a.example")
        XCTAssertEqual(store.origins, ["https://b.example"])
        store.removeAll()
        XCTAssertTrue(store.origins.isEmpty)
        let empty = SitePermissionStore(directory: directory)
        XCTAssertTrue(empty.origins.isEmpty)
    }

    func testCorruptFileFallsBackToEmpty() throws {
        let file = directory.appendingPathComponent(AppInfo.sitePermissionsFileName)
        try Data("{ not json".utf8).write(to: file)
        let store = SitePermissionStore(directory: directory)
        XCTAssertTrue(store.origins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
    }

    func testUnknownKeysAreSkipped() throws {
        let file = directory.appendingPathComponent(AppInfo.sitePermissionsFileName)
        let json = """
        {"version":1,"sites":[{"origin":"https://example.com","choices":{"popups":"block","future":"allow","camera":"nope"}}]}
        """
        try Data(json.utf8).write(to: file)
        let store = SitePermissionStore(directory: directory)
        XCTAssertEqual(store.storedChoice(origin: "https://example.com", kind: .popups), .block)
        XCTAssertNil(store.storedChoice(origin: "https://example.com", kind: .camera))
        XCTAssertEqual(store.origins, ["https://example.com"])
    }

    func testPopupAutoplayAndMediaMappingKeepAskUnchanged() {
        XCTAssertTrue(SitePermissionPolicy.allowsPopup(.ask))
        XCTAssertTrue(SitePermissionPolicy.allowsPopup(.allow))
        XCTAssertFalse(SitePermissionPolicy.allowsPopup(.block))
        XCTAssertEqual(SitePermissionPolicy.playbackOverride(.ask), .leaveDefault)
        XCTAssertEqual(SitePermissionPolicy.playbackOverride(.allow), .allowWithoutUserAction)
        XCTAssertEqual(SitePermissionPolicy.playbackOverride(.block), .requireUserAction)
        XCTAssertNil(SitePermissionPolicy.mediaDecision(for: .ask))
        XCTAssertEqual(SitePermissionPolicy.mediaDecision(for: .allow), .alwaysAllow)
        XCTAssertEqual(SitePermissionPolicy.mediaDecision(for: .block), .alwaysDeny)
        XCTAssertEqual(SitePermissionPolicy.choice(for: .alwaysAllow), .allow)
        XCTAssertEqual(SitePermissionPolicy.choice(for: .alwaysDeny), .block)
        XCTAssertNil(SitePermissionPolicy.choice(for: nil))
    }

    func testOriginKeyAndListedOrigins() {
        XCTAssertEqual(
            SitePermissionPolicy.originKey(for: URL(string: "https://Example.com/path")!),
            "https://example.com"
        )
        XCTAssertEqual(
            SitePermissionPolicy.originKey(for: URL(string: "https://example.com:8443/a")!),
            "https://example.com:8443"
        )
        XCTAssertNil(SitePermissionPolicy.originKey(for: URL(string: "about:blank")!))
        XCTAssertEqual(
            SitePermissionPolicy.listedOrigins(
                mediaOrigins: ["https://b.example", "https://a.example"],
                siteOrigins: ["https://a.example", "https://c.example"]
            ),
            ["https://a.example", "https://b.example", "https://c.example"]
        )
    }

    func testCombinedCaptureKeepsAskWhenEitherDeviceIsUnset() {
        XCTAssertNil(
            MediaPermissionPolicy.effectiveStoredDecision(
                requested: .camera,
                camera: nil,
                microphone: .alwaysAllow,
                both: .alwaysAllow
            )
        )
        XCTAssertNil(
            MediaPermissionPolicy.effectiveStoredDecision(
                requested: .microphone,
                camera: .alwaysDeny,
                microphone: nil,
                both: .alwaysDeny
            )
        )
        XCTAssertEqual(
            MediaPermissionPolicy.effectiveStoredDecision(
                requested: .both,
                camera: .alwaysDeny,
                microphone: nil,
                both: .alwaysAllow
            ),
            .alwaysAllow
        )
        XCTAssertNil(
            MediaPermissionPolicy.effectiveStoredDecision(
                requested: .both,
                camera: .alwaysDeny,
                microphone: nil,
                both: nil
            )
        )
        XCTAssertNil(
            MediaPermissionPolicy.effectiveStoredDecision(
                requested: .both,
                camera: nil,
                microphone: nil,
                both: nil
            )
        )
        XCTAssertEqual(
            MediaPermissionPolicy.effectiveStoredDecision(
                requested: .both,
                camera: .alwaysAllow,
                microphone: .alwaysAllow,
                both: nil
            ),
            .alwaysAllow
        )
        XCTAssertEqual(
            MediaPermissionPolicy.effectiveStoredDecision(
                requested: .both,
                camera: .alwaysAllow,
                microphone: .alwaysDeny,
                both: nil
            ),
            .alwaysDeny
        )
        XCTAssertEqual(
            MediaPermissionPolicy.evaluate(
                originKey: "https://example.com",
                kind: .camera,
                stored: MediaPermissionPolicy.effectiveStoredDecision(
                    requested: .camera,
                    camera: nil,
                    microphone: nil,
                    both: nil
                )
            ),
            .prompt
        )
    }

    func testDuplicateOriginKeepsTheLaterChoicesAndTheFirstPlace() throws {
        let file = directory.appendingPathComponent(AppInfo.sitePermissionsFileName)
        let json = """
        {"version":1,"sites":[
          {"origin":"https://example.com","choices":{"popups":"allow","autoplay":"block"}},
          {"origin":"https://other.example","choices":{"popups":"block"}},
          {"origin":"https://example.com","choices":{"popups":"block"}}
        ]}
        """
        try Data(json.utf8).write(to: file)
        let store = SitePermissionStore(directory: directory)
        XCTAssertEqual(store.origins, ["https://example.com", "https://other.example"])
        XCTAssertEqual(store.storedChoice(origin: "https://example.com", kind: .popups), .block)
        XCTAssertNil(store.storedChoice(origin: "https://example.com", kind: .autoplay))
        store.set(.block, origin: "https://other.example", kind: .popups)
        XCTAssertEqual(store.origins, ["https://example.com", "https://other.example"])
    }

    func testEmptyOriginIsIgnored() {
        let store = SitePermissionStore(directory: directory)
        store.set(.block, origin: "  ", kind: .popups)
        XCTAssertTrue(store.origins.isEmpty)
        store.remove(origin: "https://missing.example")
        XCTAssertTrue(store.origins.isEmpty)
    }
}
