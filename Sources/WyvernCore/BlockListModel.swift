// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum BlockListEditError: Equatable, Error {
    case invalidURL
    case duplicate
    case missingList
}

public struct BlockListFetchError: Equatable, Error, LocalizedError {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// One paused site. Newest entries stay first in `BlockListState.allowlist`.
public struct BlockListAllowEntry: Codable, Equatable, Sendable {
    public var host: String
    public var added: Date

    public init(host: String, added: Date) {
        self.host = host
        self.added = added
    }
}

/// `www.example.com` and `Example.COM` are the same site for the allowlist.
public enum BlockListAllowlist {
    public static func normalize(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }
        if host.contains("://") || host.contains("/") || host.contains("?") || host.contains("#") || host.contains(":") {
            var candidate = host
            if candidate.contains("://") == false {
                candidate = "http://" + candidate
            }
            if let extracted = URL(string: candidate)?.host?.lowercased(), !extracted.isEmpty {
                host = extracted
            }
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        // A single label such as `com` would make `*com` match every `.com` host.
        guard host.contains(".") else { return nil }
        guard let name = HostsListParser.canonicalHost(host) else { return nil }
        guard name.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        return name
    }

    public static func normalizedUnique(_ hosts: [String]) -> [String] {
        var unique = Set<String>()
        for host in hosts {
            guard let name = normalize(host) else { continue }
            unique.insert(name)
        }
        return unique.sorted()
    }

    /// Keeps the newest date for each host. Result is newest first.
    public static func normalizedEntries(_ entries: [BlockListAllowEntry]) -> [BlockListAllowEntry] {
        var dates: [String: Date] = [:]
        for entry in entries {
            guard let host = normalize(entry.host) else { continue }
            if let existing = dates[host] {
                if entry.added > existing {
                    dates[host] = entry.added
                }
            } else {
                dates[host] = entry.added
            }
        }
        return dates.map { BlockListAllowEntry(host: $0.key, added: $0.value) }
            .sorted { left, right in
                if left.added != right.added { return left.added > right.added }
                return left.host < right.host
            }
    }

    public enum InsertResult: Equatable {
        case added([BlockListAllowEntry])
        case duplicate
        case invalid
    }

    public static func inserting(_ raw: String, into entries: [BlockListAllowEntry], now: Date) -> InsertResult {
        guard let host = normalize(raw) else { return .invalid }
        if entries.contains(where: { $0.host == host }) { return .duplicate }
        var next = entries
        next.insert(BlockListAllowEntry(host: host, added: now), at: 0)
        return .added(next)
    }

    /// True when `host` or one of its parents is allowlisted. `www.` is stripped first.
    public static func covers(_ host: String, allowlist: Set<String>) -> Bool {
        guard let normalized = normalize(host) else { return false }
        var rest = normalized
        while true {
            if allowlist.contains(rest) { return true }
            guard let dot = rest.firstIndex(of: ".") else { return false }
            rest = String(rest[rest.index(after: dot)...])
        }
    }
}

/// "just now", "2 hours ago", and the same for minutes and days.
public enum BlockListRelativeTime {
    public static func phrase(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 {
            let minutes = max(1, seconds / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        if seconds < 86_400 {
            let hours = max(1, seconds / 3_600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = max(1, seconds / 86_400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}

public enum BlockListFormat {
    public static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

public struct BlockListSource: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var urlString: String
    public var isBuiltIn: Bool
    public var enabled: Bool
    public var lastUpdated: Date?
    public var domainCount: Int
    public var contentHash: String
    public var lastError: String?

    public init(
        id: String,
        name: String,
        urlString: String,
        isBuiltIn: Bool,
        enabled: Bool,
        lastUpdated: Date? = nil,
        domainCount: Int = 0,
        contentHash: String = "",
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.isBuiltIn = isBuiltIn
        self.enabled = enabled
        self.lastUpdated = lastUpdated
        self.domainCount = domainCount
        self.contentHash = contentHash
        self.lastError = lastError
    }
}

public struct BlockListState: Equatable, Sendable {
    public static let disabledCompileHash = "disabled"
    /// Rolling window for the settings line “blocked this week”.
    public static let weekLength: TimeInterval = 7 * 24 * 60 * 60

    /// Master switch. Missing state, including an upgrade that has never saved this file, stays off.
    public var blockingEnabled: Bool
    public var sources: [BlockListSource]
    /// Newest first.
    public var allowlist: [BlockListAllowEntry]
    public var compiledHash: String
    public var compileError: String?
    public var installedIdentifiers: [String]
    /// View > Show Blocked Count. Missing values stay on.
    public var showBlockedCount: Bool
    public var blockedThisWeek: Int
    public var weekStarted: Date?
    /// Custom lists whose name the user typed. A later download does not replace those names.
    public var renamedSourceIDs: [String]

    public init(
        blockingEnabled: Bool,
        sources: [BlockListSource],
        allowlist: [BlockListAllowEntry],
        compiledHash: String,
        compileError: String?,
        installedIdentifiers: [String],
        showBlockedCount: Bool = true,
        blockedThisWeek: Int = 0,
        weekStarted: Date? = nil,
        renamedSourceIDs: [String] = []
    ) {
        self.blockingEnabled = blockingEnabled
        self.sources = sources
        self.allowlist = allowlist
        self.compiledHash = compiledHash
        self.compileError = compileError
        self.installedIdentifiers = installedIdentifiers
        self.showBlockedCount = showBlockedCount
        self.blockedThisWeek = blockedThisWeek
        self.weekStarted = weekStarted
        self.renamedSourceIDs = renamedSourceIDs
    }

    public static var fresh: BlockListState {
        BlockListState(
            blockingEnabled: false,
            sources: BlockListCatalog.builtIns,
            allowlist: [],
            compiledHash: "",
            compileError: nil,
            installedIdentifiers: []
        )
    }

    public var allowlistHosts: [String] {
        allowlist.map(\.host)
    }

    public mutating func noteBlocked(_ count: Int, now: Date) {
        guard count > 0 else { return }
        if let start = weekStarted, now.timeIntervalSince(start) < Self.weekLength {
            blockedThisWeek += count
        } else {
            weekStarted = now
            blockedThisWeek = count
        }
    }

    public func rulesActive() -> Int {
        guard blockingEnabled else { return 0 }
        return sources.reduce(0) { total, source in
            source.enabled ? total + source.domainCount : total
        }
    }
}

extension BlockListState: Codable {
    private enum CodingKeys: String, CodingKey {
        case blockingEnabled
        case sources
        case allowlist
        case compiledHash
        case compileError
        case installedIdentifiers
        case showBlockedCount
        case blockedThisWeek
        case weekStarted
        case renamedSourceIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockingEnabled = try container.decodeIfPresent(Bool.self, forKey: .blockingEnabled) ?? false
        sources = try container.decodeIfPresent([BlockListSource].self, forKey: .sources) ?? []
        compiledHash = try container.decodeIfPresent(String.self, forKey: .compiledHash) ?? ""
        compileError = try container.decodeIfPresent(String.self, forKey: .compileError) ?? nil
        installedIdentifiers = try container.decodeIfPresent([String].self, forKey: .installedIdentifiers) ?? []
        showBlockedCount = try container.decodeIfPresent(Bool.self, forKey: .showBlockedCount) ?? true
        blockedThisWeek = try container.decodeIfPresent(Int.self, forKey: .blockedThisWeek) ?? 0
        weekStarted = try container.decodeIfPresent(Date.self, forKey: .weekStarted)
        renamedSourceIDs = try container.decodeIfPresent([String].self, forKey: .renamedSourceIDs) ?? []
        if let entries = try? container.decode([BlockListAllowEntry].self, forKey: .allowlist) {
            allowlist = entries
        } else if let hosts = try? container.decode([String].self, forKey: .allowlist) {
            let epoch = Date(timeIntervalSince1970: 0)
            allowlist = hosts.map { BlockListAllowEntry(host: $0, added: epoch) }
        } else {
            allowlist = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blockingEnabled, forKey: .blockingEnabled)
        try container.encode(sources, forKey: .sources)
        try container.encode(allowlist, forKey: .allowlist)
        try container.encode(compiledHash, forKey: .compiledHash)
        try container.encodeIfPresent(compileError, forKey: .compileError)
        try container.encode(installedIdentifiers, forKey: .installedIdentifiers)
        try container.encode(showBlockedCount, forKey: .showBlockedCount)
        try container.encode(blockedThisWeek, forKey: .blockedThisWeek)
        try container.encodeIfPresent(weekStarted, forKey: .weekStarted)
        try container.encode(renamedSourceIDs, forKey: .renamedSourceIDs)
    }
}

public enum BlockListCatalog {
    public static let stevenBlackID = "stevenblack-unified"
    /// Plain domains, one per line. `domainswild` (with a `*.` prefix) parses too; this URL does not need it.
    public static let oisdSmallID = "oisd-small"
    public static let stevenBlackURL = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    public static let oisdSmallURL = "https://small.oisd.nl/domainswild2"

    public static let builtIns: [BlockListSource] = [
        BlockListSource(
            id: stevenBlackID,
            name: "Ads & trackers (EasyList-compatible)",
            urlString: stevenBlackURL,
            isBuiltIn: true,
            enabled: true
        ),
        BlockListSource(
            id: oisdSmallID,
            name: "Privacy trackers (EasyPrivacy-compatible)",
            urlString: oisdSmallURL,
            isBuiltIn: true,
            enabled: true
        )
    ]

    public static func reconcile(_ state: BlockListState) -> BlockListState {
        var next = state
        var sources: [BlockListSource] = []
        for builtIn in builtIns {
            if var existing = state.sources.first(where: { $0.id == builtIn.id }) {
                existing.name = builtIn.name
                existing.urlString = builtIn.urlString
                existing.isBuiltIn = true
                sources.append(existing)
            } else {
                sources.append(builtIn)
            }
        }
        for source in state.sources where source.isBuiltIn == false {
            guard let url = BlockListURL.normalizeHTTPS(source.urlString) else { continue }
            guard sources.contains(where: { $0.id == source.id || $0.urlString == url }) == false else { continue }
            var copy = source
            copy.urlString = url
            copy.isBuiltIn = false
            sources.append(copy)
        }
        next.sources = sources
        next.allowlist = BlockListAllowlist.normalizedEntries(state.allowlist)
        return next
    }

    public static func addingCustom(url raw: String, to state: BlockListState) -> Result<BlockListState, BlockListEditError> {
        guard let url = BlockListURL.normalizeHTTPS(raw) else { return .failure(.invalidURL) }
        if state.sources.contains(where: { $0.urlString == url }) {
            return .failure(.duplicate)
        }
        var next = state
        let host = URL(string: url)?.host ?? url
        next.sources.append(BlockListSource(
            id: customID(for: url),
            name: host,
            urlString: url,
            isBuiltIn: false,
            enabled: true
        ))
        return .success(next)
    }

    public static func removingCustom(id: String, from state: BlockListState) -> BlockListState {
        var next = state
        next.sources.removeAll { $0.id == id && $0.isBuiltIn == false }
        return next
    }

    public static func customID(for normalizedURL: String) -> String {
        "custom-" + String(BlockListHash.hex(normalizedURL).prefix(16))
    }
}

public enum BlockListURL {
    public enum Problem: Equatable, Error {
        case needsHTTPS
        case invalid
    }

    /// https only, with a host and no embedded credentials.
    public static func check(_ raw: String) -> Result<String, Problem> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else { return .failure(.invalid) }
        switch components.scheme?.lowercased() {
        case "http":
            return .failure(.needsHTTPS)
        case "https":
            break
        default:
            return .failure(.invalid)
        }
        guard let normalized = normalizeHTTPS(trimmed) else { return .failure(.invalid) }
        return .success(normalized)
    }

    /// https only, with a host and no embedded credentials.
    /// Loopback, link-local, multicast, and local-only names are refused.
    /// An RFC1918, CGNAT, or IPv6 ULA address is allowed when the user typed it.
    public static func normalizeHTTPS(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return nil }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        guard components.user == nil, components.password == nil else { return nil }
        guard isAllowedListHost(host) else { return nil }
        components.scheme = "https"
        components.host = host
        components.fragment = nil
        guard let value = components.string, value.hasPrefix("https://") else { return nil }
        return value
    }

    /// Public hosts, or a literal LAN address the user named. Not a redirect target by itself.
    static func isAllowedListHost(_ host: String) -> Bool {
        if NetworkHostPolicy.isNonPublic(host) == false { return true }
        return NetworkHostPolicy.isUserSpecifiedLAN(host)
    }
}

/// Redirects while downloading a list. HTTPS only, no credentials, and a private
/// destination must be the same host the user typed. A public list may move to a
/// public CDN. It may not move onto loopback or another private host.
public enum BlockListRedirectPolicy {
    public static func shouldFollow(from: URL, to: URL?) -> Bool {
        guard let to else { return false }
        guard to.scheme?.lowercased() == "https" else { return false }
        guard to.user == nil, to.password == nil else { return false }
        guard let toHost = to.host?.lowercased(), !toHost.isEmpty else { return false }
        if NetworkHostPolicy.isNonPublic(toHost) == false { return true }
        guard NetworkHostPolicy.isUserSpecifiedLAN(toHost) else { return false }
        return toHost == from.host?.lowercased()
    }
}

public enum BlockListUpdateSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastUpdated: Date?, now: Date, force: Bool = false) -> Bool {
        if force { return true }
        guard let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) >= interval
    }

    /// Enabled lists that should be downloaded.
    /// Automatic checks do nothing while the master switch is off. "Update now" passes `force: true`.
    public static func sourcesToFetch(state: BlockListState, now: Date, force: Bool) -> [BlockListSource] {
        if force == false && state.blockingEnabled == false {
            return []
        }
        return state.sources.filter { source in
            source.enabled && isDue(lastUpdated: source.lastUpdated, now: now, force: force)
        }
    }
}

public struct ParsedBlockList: Equatable, Sendable {
    public var domains: [String]
    public var contentHash: String

    public init(domains: [String], contentHash: String) {
        self.domains = domains
        self.contentHash = contentHash
    }
}

public enum BlockListIngestResult: Equatable, Sendable {
    case accepted(ParsedBlockList, title: String?)
    case rejected(String)
}

public enum BlockListIngestor {
    public static let maxDomains = 300_000

    public static func inspect(_ body: String) -> BlockListIngestResult {
        let domains: [String]
        switch HostsListParser.parseOutcome(body) {
        case .tooLarge:
            return .rejected("List is too large (max 300,000 rules)")
        case .domains(let parsed):
            domains = parsed
        }
        if domains.isEmpty {
            return .rejected("That file isn't a filter list")
        }
        if domains.count > maxDomains {
            return .rejected("List is too large (max 300,000 rules)")
        }
        let parsed = ParsedBlockList(domains: domains, contentHash: BlockListHash.contentHash(domains: domains))
        return .accepted(parsed, title: HostsListParser.listTitle(body))
    }

    public static func prepare(_ body: String) -> ParsedBlockList {
        let domains = HostsListParser.parse(body)
        return ParsedBlockList(domains: domains, contentHash: BlockListHash.contentHash(domains: domains))
    }

    public static func commit(
        _ parsed: ParsedBlockList,
        title: String? = nil,
        sourceID: String,
        now: Date,
        state: inout BlockListState,
        store: BlockListStore
    ) throws {
        try store.writeDomains(parsed.domains, id: sourceID)
        try record(parsed, title: title, sourceID: sourceID, now: now, state: &state)
    }

    /// Updates list metadata. The domain file is already written.
    public static func record(
        _ parsed: ParsedBlockList,
        title: String?,
        sourceID: String,
        now: Date,
        state: inout BlockListState
    ) throws {
        guard let index = state.sources.firstIndex(where: { $0.id == sourceID }) else {
            throw BlockListEditError.missingList
        }
        state.sources[index].domainCount = parsed.domains.count
        state.sources[index].contentHash = parsed.contentHash
        state.sources[index].lastUpdated = now
        state.sources[index].lastError = nil
        if state.sources[index].isBuiltIn == false,
           state.renamedSourceIDs.contains(sourceID) == false,
           let title,
           title.isEmpty == false {
            state.sources[index].name = title
        }
    }

    public static func noteFailure(message: String, sourceID: String, state: inout BlockListState) {
        guard let index = state.sources.firstIndex(where: { $0.id == sourceID }) else { return }
        state.sources[index].lastError = message
    }
}

/// Cache and `state.json` under Application Support (`AppLocations` + `blocklists`).
public struct BlockListStore: Equatable, Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func defaultRoot() -> URL {
        AppLocations.dataDirectory.appendingPathComponent("blocklists", isDirectory: true)
    }

    public var stateFile: URL {
        root.appendingPathComponent("state.json")
    }

    public func load() -> BlockListState {
        guard let data = try? Data(contentsOf: stateFile) else { return .fresh }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(BlockListState.self, from: data) else { return .fresh }
        return BlockListCatalog.reconcile(state)
    }

    public func save(_ state: BlockListState) throws {
        let reconciled = BlockListCatalog.reconcile(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(reconciled)
        try PrivateFile.write(data, to: stateFile)
    }

    public func cacheURL(for id: String) -> URL {
        root
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(safeFileName(id) + ".domains")
    }

    public func writeDomains(_ domains: [String], id: String) throws {
        let url = cacheURL(for: id)
        try PrivateFile.write(Data(BlockListHash.cacheText(domains: domains).utf8), to: url)
    }

    /// `expectedHash` is the hash stored next to the list. An empty hash means the list
    /// has never been downloaded, so there is nothing to compare. A mismatch returns nothing
    /// rather than compiling a cache file that no longer matches the recorded list.
    public func readDomains(id: String, expectedHash: String = "") -> [String] {
        guard let data = try? Data(contentsOf: cacheURL(for: id)),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let domains = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if expectedHash.isEmpty == false,
           BlockListHash.contentHash(domains: domains) != expectedHash {
            return []
        }
        return domains
    }

    public func removeCache(id: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: id))
    }

    /// Domains from each enabled list, in source order. Empty when blocking is off.
    public func enabledDomainGroups(_ state: BlockListState) -> [[String]] {
        guard state.blockingEnabled else { return [] }
        return state.sources.compactMap { source in
            guard source.enabled else { return nil }
            let domains = readDomains(id: source.id, expectedHash: source.contentHash)
            return domains.isEmpty ? nil : domains
        }
    }

    private func safeFileName(_ id: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")
        let scalars = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let name = String(scalars)
        return name.isEmpty ? "list" : name
    }
}

public struct BlockListCompilePlan: Equatable, Sendable {
    public var hash: String
    public var domains: [String]
    /// Built off the main thread so allowlist toggles do not rebuild it there.
    public var domainSet: Set<String>
    public var allowlist: [String]
    public var ruleLimit: Int

    public init(
        hash: String,
        domains: [String],
        domainSet: Set<String>,
        allowlist: [String],
        ruleLimit: Int
    ) {
        self.hash = hash
        self.domains = domains
        self.domainSet = domainSet
        self.allowlist = allowlist
        self.ruleLimit = ruleLimit
    }

    public var chunkCount: Int {
        ContentRuleCompiler.chunkCount(domainCount: domains.count, ruleLimit: ruleLimit)
    }

    public var identifiers: [String] {
        (0..<chunkCount).map { "\(ContentRuleCompiler.identifierPrefix)\($0)" }
    }

    /// One chunk of JSON. `domains` is already canonical, so this does not normalize again.
    public func chunk(at index: Int) -> ContentRuleChunk? {
        ContentRuleCompiler.compilePreparedChunk(
            domains: domains,
            allowlist: allowlist,
            index: index,
            ruleLimit: ruleLimit
        )
    }

    /// Materializes every chunk. Tests and small lists use this. The controller does not.
    public var chunks: [ContentRuleChunk] {
        (0..<chunkCount).compactMap { chunk(at: $0) }
    }
}

public enum BlockListCompilePlanner {
    public static func plan(
        state: BlockListState,
        domainGroups: [[String]],
        ruleLimit: Int = ContentRuleCompiler.defaultRuleLimit
    ) -> BlockListCompilePlan {
        let limit = ContentRuleCompiler.clampedRuleLimit(ruleLimit)
        let allowlist = BlockListAllowlist.normalizedUnique(state.allowlist.map(\.host))
        guard state.blockingEnabled else {
            return BlockListCompilePlan(
                hash: BlockListState.disabledCompileHash,
                domains: [],
                domainSet: [],
                allowlist: allowlist,
                ruleLimit: limit
            )
        }
        var combined = Set<String>()
        for group in domainGroups {
            for domain in group {
                guard let name = HostsListParser.canonicalHost(domain) else { continue }
                guard name.utf8.allSatisfy({ $0 < 128 }) else { continue }
                combined.insert(name)
            }
        }
        let domains = HostsListParser.collapse(combined)
        let hash = BlockListHash.compileHash(
            domains: domains,
            allowlist: allowlist,
            templateVersion: ContentRuleCompiler.templateVersion,
            ruleLimit: limit
        )
        return BlockListCompilePlan(
            hash: hash,
            domains: domains,
            domainSet: Set(domains),
            allowlist: allowlist,
            ruleLimit: limit
        )
    }

    public static func needsCompile(state: BlockListState, plan: BlockListCompilePlan) -> Bool {
        if state.compileError != nil { return true }
        return state.compiledHash != plan.hash
    }
}

public struct BlockListUpdater {
    public typealias Fetch = (URL) throws -> String

    public static func update(
        state: inout BlockListState,
        now: Date,
        force: Bool,
        store: BlockListStore,
        fetch: Fetch
    ) {
        let due = BlockListUpdateSchedule.sourcesToFetch(state: state, now: now, force: force)
        for source in due {
            guard let url = URL(string: source.urlString) else {
                BlockListIngestor.noteFailure(message: "The list URL is invalid.", sourceID: source.id, state: &state)
                continue
            }
            do {
                let body = try fetch(url)
                switch BlockListIngestor.inspect(body) {
                case .rejected(let message):
                    BlockListIngestor.noteFailure(message: message, sourceID: source.id, state: &state)
                case .accepted(let parsed, let title):
                    try BlockListIngestor.commit(
                        parsed,
                        title: title,
                        sourceID: source.id,
                        now: now,
                        state: &state,
                        store: store
                    )
                }
            } catch let error as BlockListFetchError {
                BlockListIngestor.noteFailure(message: error.message, sourceID: source.id, state: &state)
            } catch {
                BlockListIngestor.noteFailure(message: "Could not download the list.", sourceID: source.id, state: &state)
            }
        }
    }
}

/// Hosts covered by the compiled rules, used only to estimate the badge count.
public struct BlockListMatcher: Equatable, Sendable {
    public var domains: Set<String>
    public var allowlist: Set<String>

    public init(domains: Set<String>, allowlist: Set<String>) {
        self.domains = domains
        self.allowlist = allowlist
    }

    public static let empty = BlockListMatcher(domains: [], allowlist: [])

    public func blocksHost(_ host: String) -> Bool {
        if BlockListAllowlist.covers(host, allowlist: allowlist) { return false }
        return domainCovers(host)
    }

    /// The per-site switch is on when this host is not allowlisted.
    public func blocksSite(_ host: String) -> Bool {
        BlockListAllowlist.covers(host, allowlist: allowlist) == false
            && BlockListAllowlist.normalize(host) != nil
    }

    private func domainCovers(_ host: String) -> Bool {
        guard var rest = HostsListParser.canonicalHost(host) else { return false }
        // `canonicalHost` strips a leading `*.`, which page hosts do not have.
        while true {
            if domains.contains(rest) { return true }
            guard let dot = rest.firstIndex(of: ".") else { return false }
            rest = String(rest[rest.index(after: dot)...])
        }
    }
}

/// DOM URL heuristic. See `BlockListProbe` for why this is not a WebKit block callback.
public enum BlockedRequestCounter {
    public static func host(of urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    /// Counts each new URL once when its host is covered by the block set and not allowlisted.
    public static func consume(urls: [String], seen: inout Set<String>, matcher: BlockListMatcher) -> Int {
        guard matcher.domains.isEmpty == false else { return 0 }
        var added = 0
        for url in urls {
            if seen.contains(url) { continue }
            seen.insert(url)
            guard let host = host(of: url), matcher.blocksHost(host) else { continue }
            added += 1
        }
        return added
    }
}
