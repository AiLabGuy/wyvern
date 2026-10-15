// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class ContentRuleCompilerTests: XCTestCase {
    func testEscapesDotsAndHyphens() throws {
        let chunks = ContentRuleCompiler.compile(
            domains: ["ads.example.com", "a-b.example.com"],
            allowlist: []
        )
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunk.identifier, "wyvern.blocklist.0")
        let rules = try rules(in: chunk.json)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(
            filter(rules[0]),
            "^[^:]+://+([^:/]+\\.)?a-b\\.example\\.com\\.?[:/]"
        )
        XCTAssertEqual(
            filter(rules[1]),
            "^[^:]+://+([^:/]+\\.)?ads\\.example\\.com\\.?[:/]"
        )
        XCTAssertEqual(actionType(rules[0]), "block")
        XCTAssertFalse(chunk.json.contains("a\\\\-b"))
        XCTAssertTrue(chunk.json.contains("a-b\\\\.example\\\\.com\\\\.?"))
        XCTAssertTrue(chunk.json.contains("ads\\\\.example\\\\.com"))
    }

    func testMetacharactersCannotBreakTheRuleJSON() {
        let hostile = "a.b|\"c\\d"
        let escaped = ContentRuleCompiler.jsonEscape(ContentRuleCompiler.regexEscape(hostile))
        // Every quote must be escaped, so none can end the JSON string early.
        XCTAssertFalse(escaped.replacingOccurrences(of: "\\\"", with: "").contains("\""))
        XCTAssertFalse(escaped.contains("\n"))
        let wrapped = "{\"url-filter\":\"\(escaped)\"}"
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(wrapped.utf8)))
        XCTAssertNil(HostsListParser.canonicalHost("a\"b.example"))
        XCTAssertNil(HostsListParser.canonicalHost("a|b.example"))
        XCTAssertNil(HostsListParser.canonicalHost("a$(b).example"))
        let chunks = ContentRuleCompiler.compile(domains: ["ads.example", "a\"b.example", "a|b.example"])
        let json = chunks.first?.json ?? ""
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        XCTAssertFalse(json.contains("a\"b"))
        XCTAssertFalse(json.contains("a|b"))
    }

    func testRuleLimitCapAndASCIIFilter() throws {
        XCTAssertEqual(ContentRuleCompiler.clampedRuleLimit(0), 1)
        XCTAssertEqual(ContentRuleCompiler.clampedRuleLimit(50_000), 50_000)
        XCTAssertEqual(ContentRuleCompiler.clampedRuleLimit(200_000), 149_999)
        XCTAssertEqual(ContentRuleCompiler.chunkCount(domainCount: 150_000, ruleLimit: 200_000), 2)
        XCTAssertEqual(ContentRuleCompiler.templateVersion, "v2")

        let chunks = ContentRuleCompiler.compile(
            domains: ["ads.example", "münchen.example", "com", "not ascii \u{1F600}.example"],
            allowlist: ["MÜNCHEN.test", "com"]
        )
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertTrue(chunk.json.contains("xn--mnchen-3ya"))
        XCTAssertTrue(chunk.json.contains("*xn--mnchen-3ya.test"))
        XCTAssertFalse(chunk.json.contains("ü"))
        XCTAssertFalse(chunk.json.contains("\"*com\""))
        XCTAssertTrue(chunk.json.utf8.allSatisfy { $0 < 128 })
        let rules = try rules(in: chunk.json)
        let filters = rules.compactMap(filter)
        XCTAssertTrue(filters.contains { $0.hasSuffix("\\.?[:/]") })
        XCTAssertFalse(filters.contains { $0.contains("/com\\.") })
    }

    func testChunkCounts() {
        XCTAssertEqual(ContentRuleCompiler.defaultRuleLimit, 50_000)
        XCTAssertEqual(ContentRuleCompiler.compile(domains: [], allowlist: ["example.com"]).count, 0)
        XCTAssertEqual(ContentRuleCompiler.compile(domains: ["a.com"], allowlist: []).count, 1)

        let limit = ContentRuleCompiler.defaultRuleLimit
        XCTAssertEqual(ContentRuleCompiler.compile(domains: numbered(limit), allowlist: [], ruleLimit: limit).count, 1)
        XCTAssertEqual(ContentRuleCompiler.compile(domains: numbered(limit + 1), allowlist: [], ruleLimit: limit).count, 2)
        XCTAssertEqual(ContentRuleCompiler.chunkCount(domainCount: 320_000, ruleLimit: limit), 7)
        XCTAssertEqual(
            ContentRuleCompiler.compileChunk(domains: ["a.com"], index: 0, ruleLimit: limit)?.identifier,
            "wyvern.blocklist.0"
        )
        XCTAssertEqual(
            ContentRuleCompiler.compileChunk(domains: numbered(7), index: 6, ruleLimit: 1)?.identifier,
            "wyvern.blocklist.6"
        )
        XCTAssertNil(ContentRuleCompiler.compileChunk(domains: ["a.com"], index: 1, ruleLimit: limit))
    }

    func testAllowlistIsInEveryChunkAndJSONIsValid() throws {
        let domains = ["c.example", "a.example", "b.example", "d.example"]
        let first = ContentRuleCompiler.compile(domains: domains, allowlist: ["WWW.Example.com", "other.org"], ruleLimit: 2)
        let second = ContentRuleCompiler.compile(domains: domains.reversed(), allowlist: ["other.org", "www.example.com."], ruleLimit: 2)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.identifier), ["wyvern.blocklist.0", "wyvern.blocklist.1"])
        for chunk in first {
            let parsed = try rules(in: chunk.json)
            XCTAssertEqual(parsed.count, 3)
            let ignore = parsed[2]
            XCTAssertEqual(actionType(ignore), "ignore-previous-rules")
            let trigger = ignore["trigger"] as? [String: Any]
            XCTAssertEqual(trigger?["url-filter"] as? String, ".*")
            XCTAssertEqual(trigger?["if-domain"] as? [String], ["*example.com", "*other.org"])
            XCTAssertEqual(actionType(parsed[0]), "block")
        }
    }

    func testDeterministicOrdering() {
        let left = ContentRuleCompiler.compile(domains: ["b.com", "a.com", "b.com"], allowlist: [])
        let right = ContentRuleCompiler.compile(domains: ["a.com", "b.com"], allowlist: [])
        XCTAssertEqual(left, right)
    }

    private func numbered(_ count: Int) -> [String] {
        (0..<count).map { "h\($0).example" }
    }

    private func rules(in json: String) throws -> [[String: Any]] {
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [[String: Any]])
    }

    private func filter(_ rule: [String: Any]) -> String? {
        (rule["trigger"] as? [String: Any])?["url-filter"] as? String
    }

    private func actionType(_ rule: [String: Any]) -> String? {
        (rule["action"] as? [String: Any])?["type"] as? String
    }
}
