// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class BlockListTests: XCTestCase {
    func testSHA256KnownAnswers() {
        XCTAssertEqual(
            BlockListSHA256.hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            BlockListSHA256.hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testFreshStateIsOffAndBuiltInsMatchDocumentedLists() {
        let state = BlockListState.fresh
        XCTAssertFalse(state.blockingEnabled)
        XCTAssertEqual(state.allowlist, [])
        XCTAssertEqual(state.sources.map(\.id), [BlockListCatalog.stevenBlackID, BlockListCatalog.oisdSmallID])
        XCTAssertEqual(state.sources.map(\.urlString), [BlockListCatalog.stevenBlackURL, BlockListCatalog.oisdSmallURL])
        XCTAssertEqual(BlockListCatalog.oisdSmallURL, "https://small.oisd.nl/domainswild2")
        XCTAssertTrue(state.sources.allSatisfy(\.enabled))
        XCTAssertTrue(state.sources.allSatisfy(\.isBuiltIn))
    }

    func testAllowlistNormalization() {
        XCTAssertEqual(BlockListAllowlist.normalize("WWW.Example.COM"), "example.com")
        XCTAssertEqual(BlockListAllowlist.normalize("  www.example.com. "), "example.com")
        XCTAssertEqual(BlockListAllowlist.normalize("Example.COM"), "example.com")
        XCTAssertEqual(BlockListAllowlist.normalize("www.www.example.com"), "www.example.com")
        XCTAssertEqual(BlockListAllowlist.normalize("https://www.Example.com/a"), "example.com")
        XCTAssertEqual(BlockListAllowlist.normalize("münchen.example"), "xn--mnchen-3ya.example")
        XCTAssertNil(BlockListAllowlist.normalize("www."))
        XCTAssertNil(BlockListAllowlist.normalize(""))
        XCTAssertNil(BlockListAllowlist.normalize("localhost"))
        XCTAssertNil(BlockListAllowlist.normalize("com"))
        XCTAssertEqual(
            BlockListAllowlist.normalizedUnique(["WWW.B.example", "b.example", "a.example", "not a host"]),
            ["a.example", "b.example"]
        )
    }

    func testUpdateDueAtTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(BlockListUpdateSchedule.isDue(lastUpdated: nil, now: now))
        XCTAssertFalse(BlockListUpdateSchedule.isDue(lastUpdated: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(BlockListUpdateSchedule.isDue(lastUpdated: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(BlockListUpdateSchedule.isDue(lastUpdated: now, now: now, force: true))
        XCTAssertEqual(BlockListUpdateSchedule.interval, 24 * 60 * 60)

        var state = BlockListState.fresh
        state.blockingEnabled = false
        XCTAssertTrue(BlockListUpdateSchedule.sourcesToFetch(state: state, now: now, force: false).isEmpty)
        XCTAssertEqual(BlockListUpdateSchedule.sourcesToFetch(state: state, now: now, force: true).count, 2)

        state.blockingEnabled = true
        state.sources[0].enabled = false
        state.sources[0].lastUpdated = nil
        state.sources[1].lastUpdated = now.addingTimeInterval(-86_399)
        XCTAssertTrue(BlockListUpdateSchedule.sourcesToFetch(state: state, now: now, force: false).isEmpty)
        state.sources[1].lastUpdated = now.addingTimeInterval(-86_400)
        XCTAssertEqual(
            BlockListUpdateSchedule.sourcesToFetch(state: state, now: now, force: false).map(\.id),
            [BlockListCatalog.oisdSmallID]
        )
    }

    func testCatalogPersistenceCustomListsAndReconcile() throws {
        let root = temporaryDirectory()
        let store = BlockListStore(root: root)
        var state = BlockListState.fresh
        state.blockingEnabled = true
        state.allowlist = [BlockListAllowEntry(host: "WWW.Allowed.example", added: Date(timeIntervalSince1970: 10))]
        state.sources[0].domainCount = 3
        state.sources[0].lastUpdated = Date(timeIntervalSince1970: 1_700_000_000)
        state.sources[0].contentHash = "abc"
        state = try XCTUnwrap(try? BlockListCatalog.addingCustom(url: "https://lists.example/hosts", to: state).get())
        XCTAssertEqual(BlockListCatalog.addingCustom(url: "http://lists.example/hosts", to: state), .failure(.invalidURL))
        XCTAssertEqual(BlockListCatalog.addingCustom(url: "https://lists.example/hosts", to: state), .failure(.duplicate))
        let customID = try XCTUnwrap(state.sources.last?.id)
        state = BlockListCatalog.removingCustom(id: BlockListCatalog.stevenBlackID, from: state)
        XCTAssertTrue(state.sources.contains { $0.id == BlockListCatalog.stevenBlackID })
        try store.save(state)
        var loaded = store.load()
        XCTAssertEqual(loaded.blockingEnabled, true)
        XCTAssertEqual(loaded.allowlist.map(\.host), ["allowed.example"])
        XCTAssertEqual(loaded.allowlist.first?.added, Date(timeIntervalSince1970: 10))
        XCTAssertTrue(loaded.showBlockedCount)
        XCTAssertEqual(loaded.sources.first?.domainCount, 3)
        XCTAssertEqual(loaded.sources.first?.lastUpdated, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(loaded.sources.last?.id, customID)

        loaded.sources[1].urlString = "https://evil.example/replaced"
        try store.save(loaded)
        let repaired = store.load()
        XCTAssertEqual(repaired.sources[1].urlString, BlockListCatalog.oisdSmallURL)

        try Data("not-json".utf8).write(to: store.stateFile)
        let recovered = store.load()
        XCTAssertEqual(recovered, .fresh)
    }

    func testUpdaterParsesCachesAndRecordsFailures() throws {
        let root = temporaryDirectory()
        let store = BlockListStore(root: root)
        var state = BlockListState.fresh
        state.blockingEnabled = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var fetched: [String] = []
        BlockListUpdater.update(state: &state, now: now, force: false, store: store) { url in
            fetched.append(url.absoluteString)
            if url.absoluteString == BlockListCatalog.stevenBlackURL {
                return "0.0.0.0 ads.example\n# c\nads.example\nsub.ads.example\n"
            }
            throw BlockListFetchError(message: "The list server returned an error.")
        }
        XCTAssertEqual(fetched.count, 2)
        let steven = try XCTUnwrap(state.sources.first { $0.id == BlockListCatalog.stevenBlackID })
        XCTAssertEqual(steven.domainCount, 1)
        XCTAssertEqual(steven.lastUpdated, now)
        XCTAssertNil(steven.lastError)
        XCTAssertEqual(store.readDomains(id: BlockListCatalog.stevenBlackID), ["ads.example"])
        let oisd = try XCTUnwrap(state.sources.first { $0.id == BlockListCatalog.oisdSmallID })
        XCTAssertEqual(oisd.lastError, "The list server returned an error.")
        XCTAssertNil(oisd.lastUpdated)

        fetched.removeAll()
        BlockListUpdater.update(state: &state, now: now.addingTimeInterval(60), force: false, store: store) { _ in
            fetched.append("called")
            return ""
        }
        XCTAssertEqual(fetched, ["called"])
        XCTAssertEqual(state.sources.first { $0.id == BlockListCatalog.stevenBlackID }?.domainCount, 1)
    }

    func testCompilePlanCollapsesAcrossListsAndSkipsUnchangedHash() {
        var state = BlockListState.fresh
        state.blockingEnabled = false
        let off = BlockListCompilePlanner.plan(state: state, domainGroups: [["ads.example"]])
        XCTAssertEqual(off.chunks, [])
        XCTAssertEqual(off.hash, BlockListState.disabledCompileHash)
        XCTAssertTrue(BlockListCompilePlanner.needsCompile(state: state, plan: off))

        state.blockingEnabled = true
        state.allowlist = [BlockListAllowEntry(host: "WWW.News.example", added: Date(timeIntervalSince1970: 20))]
        let plan = BlockListCompilePlanner.plan(
            state: state,
            domainGroups: [["example.com", "ads.example.com"], ["other.org", "EXAMPLE.com"]]
        )
        XCTAssertEqual(plan.domains, ["example.com", "other.org"])
        XCTAssertEqual(plan.allowlist, ["news.example"])
        XCTAssertEqual(plan.chunks.count, 1)
        XCTAssertTrue(plan.chunks[0].json.contains("\"if-domain\":[\"*news.example\"]"))
        state.compiledHash = plan.hash
        state.compileError = nil
        XCTAssertFalse(BlockListCompilePlanner.needsCompile(state: state, plan: plan))
        state.allowlist = [BlockListAllowEntry(host: "other.example", added: Date(timeIntervalSince1970: 30))]
        let changed = BlockListCompilePlanner.plan(state: state, domainGroups: [["example.com"], ["other.org"]])
        XCTAssertTrue(BlockListCompilePlanner.needsCompile(state: state, plan: changed))
        state.compileError = "Could not compile the block list."
        state.compiledHash = changed.hash
        XCTAssertTrue(BlockListCompilePlanner.needsCompile(state: state, plan: changed))
    }

    func testMatcherAndBlockedCount() {
        let matcher = BlockListMatcher(
            domains: ["example.com", "tracker.test"],
            allowlist: ["news.example"]
        )
        XCTAssertTrue(matcher.blocksHost("ads.example.com"))
        XCTAssertTrue(matcher.blocksHost("example.com"))
        XCTAssertFalse(matcher.blocksHost("notexample.com"))
        XCTAssertFalse(matcher.blocksHost("www.news.example"))
        XCTAssertFalse(matcher.blocksHost("a.news.example"))
        XCTAssertTrue(matcher.blocksHost("tracker.test"))
        XCTAssertFalse(matcher.blocksSite("WWW.News.example"))
        XCTAssertTrue(matcher.blocksSite("tracker.test"))

        var seen = Set<String>()
        let first = BlockedRequestCounter.consume(
            urls: [
                "https://ads.example.com/a.js",
                "https://ads.example.com/a.js",
                "https://cdn.tracker.test/pixel",
                "https://www.news.example/logo.png",
                "https://unrelated.test/ok",
                "data:text/plain,hi"
            ],
            seen: &seen,
            matcher: matcher
        )
        XCTAssertEqual(first, 2)
        let second = BlockedRequestCounter.consume(
            urls: ["https://ads.example.com/a.js", "https://ads.example.com/b.js"],
            seen: &seen,
            matcher: matcher
        )
        XCTAssertEqual(second, 1)
    }

    func testCompileHashIncludesTemplateAndLimit() {
        let left = BlockListHash.compileHash(
            domains: ["a.com"],
            allowlist: ["b.com"],
            templateVersion: "v2",
            ruleLimit: 50_000
        )
        let otherLimit = BlockListHash.compileHash(
            domains: ["a.com"],
            allowlist: ["b.com"],
            templateVersion: "v2",
            ruleLimit: 50_001
        )
        let otherVersion = BlockListHash.compileHash(
            domains: ["a.com"],
            allowlist: ["b.com"],
            templateVersion: "v3",
            ruleLimit: 50_000
        )
        XCTAssertNotEqual(left, otherLimit)
        XCTAssertNotEqual(left, otherVersion)
        var state = BlockListState.fresh
        state.blockingEnabled = true
        let plan = BlockListCompilePlanner.plan(state: state, domainGroups: [["a.com"]], ruleLimit: 50_000)
        let wider = BlockListCompilePlanner.plan(state: state, domainGroups: [["a.com"]], ruleLimit: 40_000)
        XCTAssertNotEqual(plan.hash, wider.hash)
        XCTAssertEqual(plan.domainSet, ["a.com"])
    }

    func testRelativeTimeAndLegacyAllowlist() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(BlockListRelativeTime.phrase(since: now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(BlockListRelativeTime.phrase(since: now.addingTimeInterval(-120), now: now), "2 minutes ago")
        XCTAssertEqual(BlockListRelativeTime.phrase(since: now.addingTimeInterval(-7_200), now: now), "2 hours ago")
        XCTAssertEqual(BlockListRelativeTime.phrase(since: now.addingTimeInterval(-172_800), now: now), "2 days ago")

        let root = temporaryDirectory()
        let store = BlockListStore(root: root)
        let legacy = """
        {"allowlist":["WWW.Old.example","com"],"blockingEnabled":true,"compiledHash":"","installedIdentifiers":[],"sources":[]}
        """
        try Data(legacy.utf8).write(to: store.stateFile)
        let loaded = store.load()
        XCTAssertEqual(loaded.allowlist.map(\.host), ["old.example"])
        XCTAssertTrue(loaded.showBlockedCount)
        XCTAssertEqual(loaded.sources.map(\.id), [BlockListCatalog.stevenBlackID, BlockListCatalog.oisdSmallID])
        XCTAssertEqual(loaded.sources.map(\.name), [
            "Ads & trackers (EasyList-compatible)",
            "Privacy trackers (EasyPrivacy-compatible)"
        ])
    }

    func testAllowlistInsertIsNewestFirst() {
        let now = Date(timeIntervalSince1970: 50)
        guard case .added(let first) = BlockListAllowlist.inserting("Example.com", into: [], now: now) else {
            return XCTFail("expected add")
        }
        guard case .added(let second) = BlockListAllowlist.inserting("https://www.Other.org/a", into: first, now: now.addingTimeInterval(5)) else {
            return XCTFail("expected add")
        }
        XCTAssertEqual(second.map(\.host), ["other.org", "example.com"])
        XCTAssertEqual(BlockListAllowlist.inserting("www.example.com", into: second, now: now), .duplicate)
        XCTAssertEqual(BlockListAllowlist.inserting("com", into: second, now: now), .invalid)
    }

    func testCustomListURLAndRedirectHosts() {
        XCTAssertEqual(
            BlockListURL.normalizeHTTPS("https://lists.example.invalid/a.txt"),
            "https://lists.example.invalid/a.txt"
        )
        XCTAssertEqual(
            BlockListURL.normalizeHTTPS("https://192.168.1.5/hosts.txt"),
            "https://192.168.1.5/hosts.txt"
        )
        XCTAssertNil(BlockListURL.normalizeHTTPS("http://lists.example.invalid/a.txt"))
        XCTAssertNil(BlockListURL.normalizeHTTPS("file:///etc/hosts"))
        XCTAssertNil(BlockListURL.normalizeHTTPS("https://127.0.0.1/hosts"))
        XCTAssertNil(BlockListURL.normalizeHTTPS("https://[::1]/hosts"))
        XCTAssertNil(BlockListURL.normalizeHTTPS("https://localhost/hosts"))
        XCTAssertNil(BlockListURL.normalizeHTTPS("https://nas.local/hosts"))
        XCTAssertNil(BlockListURL.normalizeHTTPS("https://169.254.169.254/latest"))
        XCTAssertNil(BlockListURL.normalizeHTTPS("https://user:pass@lists.example.invalid/a"))
        XCTAssertEqual(BlockListURL.check("http://lists.example.invalid/a").map(\.isEmpty), .failure(.needsHTTPS))

        let from = URL(string: "https://lists.example.invalid/a")!
        XCTAssertTrue(BlockListRedirectPolicy.shouldFollow(from: from, to: URL(string: "https://cdn.example.invalid/a")))
        XCTAssertFalse(BlockListRedirectPolicy.shouldFollow(from: from, to: URL(string: "http://cdn.example.invalid/a")))
        XCTAssertFalse(BlockListRedirectPolicy.shouldFollow(from: from, to: URL(string: "https://10.1.2.3/a")))
        XCTAssertFalse(BlockListRedirectPolicy.shouldFollow(from: from, to: URL(string: "https://127.0.0.1/a")))
        XCTAssertFalse(BlockListRedirectPolicy.shouldFollow(from: from, to: URL(string: "https://u:p@cdn.example.invalid/a")))
        let lan = URL(string: "https://10.1.2.3/a")!
        XCTAssertTrue(BlockListRedirectPolicy.shouldFollow(from: lan, to: URL(string: "https://10.1.2.3/b")))
        XCTAssertFalse(BlockListRedirectPolicy.shouldFollow(from: lan, to: URL(string: "https://10.9.9.9/b")))
    }

    func testCacheHashMismatchDropsDomains() throws {
        let store = BlockListStore(root: temporaryDirectory())
        try store.writeDomains(["ads.example"], id: "custom")
        let hash = BlockListHash.contentHash(domains: ["ads.example"])
        XCTAssertEqual(store.readDomains(id: "custom", expectedHash: hash), ["ads.example"])
        XCTAssertEqual(store.readDomains(id: "custom", expectedHash: "nope"), [])
        XCTAssertEqual(store.readDomains(id: "custom"), ["ads.example"])
    }

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wyvern-blocklist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
