// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One WKContentRuleList payload. Identifiers are `wyvern.blocklist.<n>` in chunk order.
public struct ContentRuleChunk: Equatable, Sendable {
    public var identifier: String
    public var json: String

    public init(identifier: String, json: String) {
        self.identifier = identifier
        self.json = json
    }
}

/// Turns domains into WebKit content-blocker JSON.
///
/// Each block rule uses
/// `^[^:]+://+([^:/]+\.)?<escaped-domain>\.?[:/]`
/// so the name, its subdomains, a port, and a trailing-dot FQDN match.
/// An allowlist entry becomes one `ignore-previous-rules` rule with
/// `"if-domain": ["*example.com"]` appended to every chunk. Lists are independent,
/// so a rule in a later chunk cannot undo a block in an earlier chunk.
/// The allowlist rule is extra: `ruleLimit` counts block rules only, and stays
/// at most 149_999 so the extra rule is still under WebKit's 150_000.
public enum ContentRuleCompiler {
    public static let defaultRuleLimit = 50_000
    /// One below WebKit's per-list cap. The allowlist rule occupies the last slot.
    public static let maxRuleLimit = 149_999
    public static let identifierPrefix = "wyvern.blocklist."
    /// Bump when the url-filter template or the JSON shape changes.
    public static let templateVersion = "v2"

    public static func clampedRuleLimit(_ ruleLimit: Int) -> Int {
        min(max(1, ruleLimit), maxRuleLimit)
    }

    /// How many chunks `domainCount` block rules need. Does not build JSON.
    public static func chunkCount(domainCount: Int, ruleLimit: Int = defaultRuleLimit) -> Int {
        guard domainCount > 0 else { return 0 }
        let limit = clampedRuleLimit(ruleLimit)
        return (domainCount + limit - 1) / limit
    }

    public static func compile(
        domains: [String],
        allowlist: [String] = [],
        ruleLimit: Int = defaultRuleLimit
    ) -> [ContentRuleChunk] {
        let unique = normalizedDomains(domains)
        let count = chunkCount(domainCount: unique.count, ruleLimit: ruleLimit)
        guard count > 0 else { return [] }
        var chunks: [ContentRuleChunk] = []
        chunks.reserveCapacity(count)
        for index in 0..<count {
            if let chunk = compilePreparedChunk(
                domains: unique,
                allowlist: allowlist,
                index: index,
                ruleLimit: ruleLimit
            ) {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    /// JSON for one chunk. `domains` may be un-normalized; non-ASCII names are dropped.
    public static func compileChunk(
        domains: [String],
        allowlist: [String] = [],
        index: Int,
        ruleLimit: Int = defaultRuleLimit
    ) -> ContentRuleChunk? {
        compilePreparedChunk(
            domains: normalizedDomains(domains),
            allowlist: allowlist,
            index: index,
            ruleLimit: ruleLimit
        )
    }

    /// JSON for one chunk of names that are already canonical. Does not copy or re-sort them.
    static func compilePreparedChunk(
        domains: [String],
        allowlist: [String],
        index: Int,
        ruleLimit: Int
    ) -> ContentRuleChunk? {
        let limit = clampedRuleLimit(ruleLimit)
        guard domains.isEmpty == false else { return nil }
        let count = (domains.count + limit - 1) / limit
        guard index >= 0, index < count else { return nil }
        let start = index * limit
        let end = min(start + limit, domains.count)
        let ignore = ignoreRule(asciiAllowlist(allowlist))
        let json = encode(domains: domains[start..<end], ignore: ignore)
        return ContentRuleChunk(identifier: "\(identifierPrefix)\(index)", json: json)
    }

    /// Lowercased, de-dotted, punycoded, deduped, sorted. Drops anything still non-ASCII.
    static func normalizedDomains(_ domains: [String]) -> [String] {
        var unique = Set<String>()
        unique.reserveCapacity(domains.count)
        for domain in domains {
            guard let name = HostsListParser.canonicalHost(domain) else { continue }
            guard name.utf8.allSatisfy({ $0 < 128 }) else { continue }
            unique.insert(name)
        }
        return unique.sorted()
    }

    static func regexEscape(_ domain: String) -> String {
        var out = ""
        out.reserveCapacity(domain.count * 2)
        // `-` is only special inside `[]`. Leaving it literal keeps the filter in the WebKit subset.
        let specials: Set<Character> = [".", "\\", "+", "*", "?", "^", "$", "(", ")", "[", "]", "{", "}", "|"]
        for character in domain {
            if specials.contains(character) {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    static func jsonEscape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 4)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\":
                out.append("\\\\")
            case "\"":
                out.append("\\\"")
            case "\n":
                out.append("\\n")
            case "\r":
                out.append("\\r")
            case "\t":
                out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    static func asciiAllowlist(_ allowlist: [String]) -> [String] {
        BlockListAllowlist.normalizedUnique(allowlist).filter { host in
            host.utf8.allSatisfy { $0 < 128 }
        }
    }

    private static func ignoreRule(_ hosts: [String]) -> String? {
        guard !hosts.isEmpty else { return nil }
        let domains = hosts.map { "\"*\(jsonEscape($0))\"" }.joined(separator: ",")
        return "{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\(domains)]},\"action\":{\"type\":\"ignore-previous-rules\"}}"
    }

    private static func encode(domains: ArraySlice<String>, ignore: String?) -> String {
        var json = "["
        let extra = ignore?.count ?? 0
        json.reserveCapacity(domains.count * 96 + extra + 2)
        for (offset, domain) in domains.enumerated() {
            if offset > 0 {
                json.append(",")
            }
            // The prefix is already JSON-escaped (`\\.` is one backslash in the regex).
            json.append("{\"trigger\":{\"url-filter\":\"^[^:]+://+([^:/]+\\\\.)?")
            json.append(jsonEscape(regexEscape(domain)))
            json.append("\\\\.?[:/]\"},\"action\":{\"type\":\"block\"}}")
        }
        if let ignore {
            if !domains.isEmpty {
                json.append(",")
            }
            json.append(ignore)
        }
        json.append("]")
        return json
    }
}
