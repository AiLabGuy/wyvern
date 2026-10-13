// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import App1Core

final class UpdateFeedTests: XCTestCase {
    private let feedURL = URL(string: "https://updates.example.invalid/wyvern/latest.json")!
    private let commit = String(repeating: "ab", count: 20)

    private func latest(_ fields: [String: Any]) throws -> Data {
        var object: [String: Any] = [
            "format": 1,
            "version": "0.2.0",
            "build": 7,
            "commit": commit,
            "zip_url": "WyvernBrowser-0.2.0-b7.zip"
        ]
        for (key, value) in fields {
            object[key] = value
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func parse(_ data: Data) throws -> UpdateCandidate {
        try UpdateFeed.parse(data, feedURL: feedURL, basename: "WyvernBrowser", allowsDevHTTP: false)
    }

    func testLatestJSONRelativeZipResolvesBesideFeed() throws {
        let candidate = try parse(try latest(["notes": "Fixes."]))
        XCTAssertEqual(candidate.version, "0.2.0")
        XCTAssertEqual(candidate.build, 7)
        XCTAssertEqual(candidate.commit, commit)
        XCTAssertEqual(candidate.notes, "Fixes.")
        XCTAssertEqual(candidate.zipURL.absoluteString, "https://updates.example.invalid/wyvern/WyvernBrowser-0.2.0-b7.zip")
        XCTAssertEqual(candidate.zipName.dmgName, "WyvernBrowser-0.2.0.dmg")
    }

    func testRelativeZipResolvesAgainstGitHubLatestDownload() throws {
        let github = URL(string: "https://github.com/owner/repo/releases/latest/download/latest.json")!
        let candidate = try UpdateFeed.parse(try latest([:]), feedURL: github, basename: "WyvernBrowser", allowsDevHTTP: false)
        XCTAssertEqual(
            candidate.zipURL.absoluteString,
            "https://github.com/owner/repo/releases/latest/download/WyvernBrowser-0.2.0-b7.zip"
        )
    }

    func testLatestJSONAbsoluteHTTPSZipOnAnotherHost() throws {
        let candidate = try parse(try latest(["zip_url": "https://cdn.example.invalid/r/WyvernBrowser-0.2.0-b7.zip"]))
        XCTAssertEqual(candidate.zipURL.host, "cdn.example.invalid")
    }

    func testLatestJSONRejectsHTTPAndCredentialAssets() {
        XCTAssertThrowsError(try parse(try latest(["zip_url": "http://cdn.example.invalid/WyvernBrowser-0.2.0-b7.zip"]))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .assetURLRejected)
        }
        XCTAssertThrowsError(try parse(try latest(["zip_url": "https://u:p@cdn.example.invalid/WyvernBrowser-0.2.0-b7.zip"]))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .assetURLRejected)
        }
        XCTAssertThrowsError(try parse(try latest(["zip_url": "file:///tmp/WyvernBrowser-0.2.0-b7.zip"]))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .assetURLRejected)
        }
    }

    func testLatestJSONMetadataMustMatchZipName() {
        XCTAssertThrowsError(try parse(try latest(["build": 8]))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .metadataMismatch)
        }
        XCTAssertThrowsError(try parse(try latest(["zip_url": "Other-0.2.0-b7.zip"]))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .assetURLRejected)
        }
    }

    func testLatestJSONFieldValidation() {
        XCTAssertThrowsError(try parse(try latest(["format": 2]))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .unsupportedFormat)
        }
        XCTAssertThrowsError(try parse(try latest(["commit": "abc"]))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .malformed)
        }
        XCTAssertThrowsError(try parse(try latest(["version": "0.2.x"]))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .malformed)
        }
        XCTAssertThrowsError(try parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .malformed)
        }
        XCTAssertThrowsError(try parse(Data("nope".utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .malformed)
        }
        XCTAssertThrowsError(try parse(Data(repeating: 0x20, count: UpdateFeed.maxFeedBytes + 1))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .tooLarge)
        }
    }

    func testGiteaCommentsPickNewestAndReadCommit() throws {
        let other = String(repeating: "c", count: 40)
        let comments: [[String: Any]] = [
            [
                "body": "DMG build run 1 commit \(other)\nsize 1 bytes",
                "attachments": [["name": "WyvernBrowser-0.1.0-b9.zip", "browser_download_url": "https://git.example.invalid/a/1"]]
            ],
            [
                "body": "DMG build run 2 commit \(commit)\nsize 1 bytes",
                "attachments": [
                    ["name": "WyvernBrowser-0.2.0-b10.zip", "browser_download_url": "https://git.example.invalid/a/2"],
                    ["name": "notes.zip", "browser_download_url": "https://git.example.invalid/a/3"]
                ]
            ],
            [
                "body": "no commit here",
                "attachments": [["name": "WyvernBrowser-0.3.0-b11.zip", "browser_download_url": "http://git.example.invalid/a/4"]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: comments)
        let candidate = try parse(data)
        XCTAssertEqual(candidate.zipName.fileName, "WyvernBrowser-0.2.0-b10.zip", "the http attachment must be skipped")
        XCTAssertEqual(candidate.commit, commit)
        XCTAssertThrowsError(try parse(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError, .noUpdateListed)
        }
    }

    func testCandidateOrderMatchesIsNewer() throws {
        let name = try XCTUnwrap(UpdateZipName.parse(fileName: "WyvernBrowser-0.1.0-b9.zip", basename: "WyvernBrowser"))
        let newerName = try XCTUnwrap(UpdateZipName.parse(fileName: "WyvernBrowser-0.2.0-b2.zip", basename: "WyvernBrowser"))
        let url = URL(string: "https://example.invalid/z")!
        let old = UpdateCandidate(version: "0.1.0", build: 9, commit: nil, zipURL: url, zipName: name)
        let new = UpdateCandidate(version: "0.2.0", build: 2, commit: nil, zipURL: url, zipName: newerName)
        XCTAssertTrue(UpdateFeed.isOrderedBefore(old, new))
        XCTAssertFalse(UpdateFeed.isOrderedBefore(new, old))
    }

    func testPrivateLANFeedRejectedWithoutDevHTTP() throws {
        let feedURL = URL(string: "http://10.0.0.2:8080/wyvern-dev/latest.json")!
        XCTAssertThrowsError(
            try UpdateFeed.parse(try latest([:]), feedURL: feedURL, basename: "WyvernBrowser", allowsDevHTTP: false)
        ) { error in
            XCTAssertEqual(error as? UpdateFeedError, .assetURLRejected)
        }
    }

    #if WYVERN_DEV_UPDATER
    func testPrivateLANFeedAcceptedInDevUpdater() throws {
        let feedURL = URL(string: "http://10.0.0.2:8080/wyvern-dev/latest.json")!
        let candidate = try UpdateFeed.parse(
            try latest([:]),
            feedURL: feedURL,
            basename: "WyvernBrowser",
            allowsDevHTTP: true
        )
        XCTAssertEqual(candidate.zipURL.scheme, "http")
        XCTAssertEqual(candidate.zipURL.host, "10.0.0.2")
        XCTAssertEqual(candidate.zipURL.lastPathComponent, "WyvernBrowser-0.2.0-b7.zip")
    }
    #endif

    func testRedirectPolicy() {
        let from = URL(string: "https://git.example.invalid/a")!
        XCTAssertTrue(UpdateRedirectPolicy.shouldFollow(from: from, to: URL(string: "https://git.example.invalid/b"), allowsDevHTTP: false))
        XCTAssertTrue(UpdateRedirectPolicy.shouldFollow(from: from, to: URL(string: "https://cdn.example.invalid/b"), allowsDevHTTP: false))
        XCTAssertFalse(UpdateRedirectPolicy.shouldFollow(from: from, to: URL(string: "http://git.example.invalid/b"), allowsDevHTTP: true))
        XCTAssertFalse(UpdateRedirectPolicy.shouldFollow(from: from, to: URL(string: "https://u:p@git.example.invalid/b"), allowsDevHTTP: false))
        XCTAssertFalse(UpdateRedirectPolicy.shouldFollow(from: from, to: URL(string: "file:///etc/hosts"), allowsDevHTTP: false))
        XCTAssertFalse(UpdateRedirectPolicy.shouldFollow(from: from, to: nil, allowsDevHTTP: false))
        // GitHub release downloads redirect from github.com to a githubusercontent.com CDN host over HTTPS.
        let github = URL(string: "https://github.com/owner/repo/releases/latest/download/latest.json")!
        XCTAssertTrue(UpdateRedirectPolicy.shouldFollow(
            from: github,
            to: URL(string: "https://objects.githubusercontent.com/github-production-release-asset/1/latest.json"),
            allowsDevHTTP: false
        ))
        XCTAssertTrue(UpdateRedirectPolicy.shouldFollow(
            from: github,
            to: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/x.zip"),
            allowsDevHTTP: false
        ))
    }
}
