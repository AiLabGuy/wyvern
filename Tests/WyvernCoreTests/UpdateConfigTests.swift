// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class UpdateConfigTests: XCTestCase {
    private let commit = String(repeating: "d", count: 40)

    func testDevFlagMatchesBuild() {
        #if WYVERN_DEV_UPDATER
        XCTAssertTrue(isDevUpdaterCompiled)
        #else
        XCTAssertFalse(isDevUpdaterCompiled)
        XCTAssertFalse(
            UpdateTransportPolicy.allowsHTTP(host: "192.168.1.8", isDevUpdaterCompiled: false, devSourceRequested: true)
        )
        #endif
    }

    func testHTTPSAccepted() {
        let result = UpdateTransportPolicy.parseSourceURL("https://example.invalid/latest.json", allowsDevHTTP: false)
        XCTAssertEqual(result.map(\.scheme), .success("https"))
    }

    func testLoopbackAndLinkLocalSourcesRejected() {
        let samples = [
            "https://127.0.0.1/latest.json",
            "https://127.0.0.2/latest.json",
            "https://[::1]/latest.json",
            "https://localhost/latest.json",
            "https://169.254.169.254/latest.json",
            "https://0177.0.0.1/latest.json",
            "https://2130706433/latest.json",
            "https://0x7f000001/latest.json"
        ]
        for sample in samples {
            switch UpdateTransportPolicy.parseSourceURL(sample, allowsDevHTTP: false) {
            case .failure(let error):
                XCTAssertEqual(error, .restrictedHost, sample)
            case .success:
                XCTFail("accepted \(sample)")
            }
        }
        switch UpdateTransportPolicy.parseSourceURL("https://192.168.1.5/latest.json", allowsDevHTTP: false) {
        case .success(let url):
            XCTAssertEqual(url.host, "192.168.1.5")
        case .failure(let error):
            XCTFail("\(error)")
        }
    }

    func testAssetURLCannotLeaveTheSourceHostForAPrivateTarget() {
        let feed = URL(string: "https://updates.example.invalid/wyvern/latest.json")!
        let zip = "WyvernBrowser-0.2.0-b7.zip"
        func host(of url: String, feedURL: URL) -> Result<String?, UpdateSourceError> {
            UpdateTransportPolicy.checkAssetURL(URL(string: url)!, feedURL: feedURL, allowsDevHTTP: false).map(\.host)
        }
        XCTAssertEqual(host(of: "https://cdn.example.invalid/\(zip)", feedURL: feed), .success("cdn.example.invalid"))
        XCTAssertEqual(host(of: "https://127.0.0.1/\(zip)", feedURL: feed), .failure(.restrictedHost))
        XCTAssertEqual(host(of: "https://10.1.2.3/\(zip)", feedURL: feed), .failure(.restrictedHost))
        let lanFeed = URL(string: "https://10.1.2.3/latest.json")!
        XCTAssertEqual(host(of: "https://10.1.2.3/\(zip)", feedURL: lanFeed), .success("10.1.2.3"))
        XCTAssertEqual(host(of: "https://10.9.9.9/\(zip)", feedURL: lanFeed), .failure(.restrictedHost))
    }

    func testOlderAndEqualVersionsAreNotNewer() {
        XCTAssertTrue(UpdateVersion.isNewer(remoteVersion: "0.2.0", remoteBuild: "1", localVersion: "0.1.0", localBuild: "9"))
        XCTAssertTrue(UpdateVersion.isNewer(remoteVersion: "0.1.0", remoteBuild: "3", localVersion: "0.1.0", localBuild: "2"))
        XCTAssertFalse(UpdateVersion.isNewer(remoteVersion: "0.1.0", remoteBuild: "2", localVersion: "0.1.0", localBuild: "2"))
        XCTAssertFalse(UpdateVersion.isNewer(remoteVersion: "0.1.0", remoteBuild: "1", localVersion: "0.1.0", localBuild: "2"))
        XCTAssertFalse(UpdateVersion.isNewer(remoteVersion: "0.1.0", remoteBuild: "99", localVersion: "0.2.0", localBuild: "1"))
        XCTAssertFalse(UpdateVersion.isNewer(remoteVersion: "0.1.0", remoteBuild: "nope", localVersion: "0.1.0", localBuild: "1"))
        XCTAssertEqual(UpdateVersion.compareVersion("0.1.0", "0.1.0"), 0)
        XCTAssertEqual(UpdateVersion.compareVersion("0.1", "0.1.0"), 0)
        XCTAssertEqual(UpdateVersion.compareVersion("1.0.0", "0.9.9"), 1)
    }

    func testVersionBuildCommitValidators() {
        XCTAssertTrue(UpdateVersion.isValidVersion("0.1.0"))
        XCTAssertFalse(UpdateVersion.isValidVersion("0..1"))
        XCTAssertFalse(UpdateVersion.isValidVersion("1.0-beta"))
        XCTAssertFalse(UpdateVersion.isValidVersion("1.9999999999"))
        XCTAssertTrue(UpdateVersion.isValidBuild("0"))
        XCTAssertTrue(UpdateVersion.isValidBuild("42"))
        XCTAssertFalse(UpdateVersion.isValidBuild("042"))
        XCTAssertFalse(UpdateVersion.isValidBuild("-1"))
        XCTAssertFalse(UpdateVersion.isValidBuild("+1"))
        XCTAssertTrue(UpdateVersion.isValidCommit(commit))
        XCTAssertFalse(UpdateVersion.isValidCommit("abc"))
    }

    /// CI signs `wyvern version= build= commit= file=`; stock `minisign -t` users may omit the
    /// prefix, reorder keys, or omit `file=`. Anything else is refused.
    func testTrustedCommentForms() {
        let ci = TrustedUpdateComment.parse("wyvern version=0.2.0 build=7 commit=\(commit) file=App-0.2.0.dmg")
        XCTAssertEqual(ci, TrustedUpdateComment(version: "0.2.0", build: "7", commit: commit, file: "App-0.2.0.dmg"))
        let stock = TrustedUpdateComment.parse("commit=\(commit.uppercased()) build=7 version=0.2.0")
        XCTAssertEqual(stock, TrustedUpdateComment(version: "0.2.0", build: "7", commit: commit, file: nil))
        XCTAssertEqual(ci?.line, "wyvern version=0.2.0 build=7 commit=\(commit) file=App-0.2.0.dmg")
        XCTAssertNil(TrustedUpdateComment.parse("version=0.2.0 build=7"))
        XCTAssertNil(TrustedUpdateComment.parse("version=0.2.0 build=7 commit=\(commit) commit=\(commit)"))
        XCTAssertNil(TrustedUpdateComment.parse("version=0.2.0 build=7 commit=\(commit) extra=1"))
        XCTAssertNil(TrustedUpdateComment.parse("version=0.2.0 build=02 commit=\(commit)"))
        XCTAssertNil(TrustedUpdateComment.parse("version=0.2.0 build=7 commit=abc"))
        XCTAssertNil(TrustedUpdateComment.parse("version=0.2.0 build=7 commit=\(commit) file=../x.dmg"))
        XCTAssertNil(TrustedUpdateComment.parse("timestamp:1700000000\tfile:App-0.2.0.dmg.sha256"))
        XCTAssertNil(TrustedUpdateComment.parse("other version=0.2.0 build=7 commit=\(commit)"))
    }

    func testChecksumParse() {
        let hex = String(repeating: "a", count: 64)
        XCTAssertEqual(SHA256Util.parseChecksumFile("\(hex)  file.dmg\n"), hex)
        let record = SHA256Util.parseChecksumRecord("\(hex)  file.dmg\n")
        XCTAssertEqual(record?.fileName, "file.dmg")
        XCTAssertNil(SHA256Util.parseChecksumFile("not-a-hash"))
        XCTAssertNil(SHA256Util.parseChecksumRecord("\(hex)  dir/file.dmg\n"))
        XCTAssertNil(SHA256Util.parseChecksumRecord("\(hex)  ..\n"))
    }
}
