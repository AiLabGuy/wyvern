// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import Foundation
import WebKit

extension Notification.Name {
    /// Settings and the toolbar badge. `userInfo` has `rulesChanged` and `reloadActive` (Bool).
    static let wyvernBlockListStateDidChange = Notification.Name("\(AppInfo.bundleIdentifier).blockListStateDidChange")
    /// Content rules were installed or cleared. Tabs add them without dropping cookie rules.
    static let wyvernBlockRulesDidChange = Notification.Name("\(AppInfo.bundleIdentifier).blockRulesDidChange")
}

/// Downloads host lists, compiles WKContentRuleList chunks, and remembers the allowlist.
/// Compile JSON is built off the main thread. WebKit store calls stay on the main thread.
@MainActor
final class BlockListController {
    static let shared = BlockListController()

    private(set) var isUpdating = false
    /// True after the compile that just finished published a state notification.
    private(set) var compileDidPublish = false
    /// True when that compile changed the installed rule lists.
    private(set) var lastCompileRulesChanged = false

    private var started = false
    private var store: BlockListStore?
    private var state = BlockListState.fresh
    private var matcher = BlockListMatcher.empty
    private var timer: Timer?
    private var pendingForce = false
    /// A non-forced update arrived while a download was already running.
    private var pendingFollowUp = false
    private var compileGeneration = 0
    private var compileWaiters: [(Bool) -> Void] = []
    private var reloadAfterCompile = false
    /// True only for the latest compile that an allowlist edit started. A list-data failure must not roll that edit back.
    private var allowlistCompile = false
    private var installedHash: String?
    /// Allowlist that matches the rule lists currently installed. Restored only when an allowlist compile fails.
    private var installedAllowlist: [BlockListAllowEntry] = []
    private var pendingRetryIDs: [String] = []
    private var blockedSavePending = false
    private let maxDownloadBytes = 80 * 1024 * 1024

    private init() {}

    var blockingEnabled: Bool {
        ensureStarted()
        return state.blockingEnabled
    }

    var showBlockedCount: Bool {
        ensureStarted()
        return state.showBlockedCount
    }

    var rulesActive: Int {
        ensureStarted()
        return state.rulesActive()
    }

    var blockedThisWeek: Int {
        ensureStarted()
        return state.blockedThisWeek
    }

    var snapshot: BlockListState {
        ensureStarted()
        return state
    }

    /// Host shown on the badge. Lowercased, trailing dots removed, `www` kept.
    static func displayHost(_ url: URL?) -> String? {
        guard var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host.isEmpty ? nil : host
    }

    func siteToggleEnabled(host: String?) -> Bool {
        guard let host else { return false }
        return BlockListAllowlist.normalize(host) != nil
    }

    /// On when this host is not allowlisted. Reads the saved allowlist, not the in-flight matcher.
    func blocksSite(host: String?) -> Bool {
        guard let host, siteToggleEnabled(host: host) else { return false }
        return BlockListAllowlist.covers(host, allowlist: Set(state.allowlistHosts)) == false
    }

    func consume(urls: [String], seen: inout Set<String>) -> Int {
        guard state.blockingEnabled else { return 0 }
        let added = BlockedRequestCounter.consume(urls: urls, seen: &seen, matcher: matcher)
        if added > 0 {
            state.noteBlocked(added, now: Date())
            scheduleBlockedSave()
        }
        return added
    }

    /// Call after `AppLocations.apply`. Later calls are ignored.
    func start() {
        guard !started else { return }
        started = true
        let root = BlockListStore.defaultRoot()
        store = BlockListStore(root: root)
        state = store?.load() ?? .fresh
        installedAllowlist = state.allowlist
        matcher = BlockListMatcher(domains: [], allowlist: Set(state.allowlistHosts))
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in
                BlockListController.shared.update(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        compileIfNeeded(reloadActive: false)
        update(force: false)
    }

    func setBlockingEnabled(_ enabled: Bool) {
        ensureStarted()
        guard state.blockingEnabled != enabled else { return }
        state.blockingEnabled = enabled
        save()
        publish(rulesChanged: false, reloadActive: false)
        if enabled {
            update(force: false)
        }
        compileIfNeeded(reloadActive: false)
    }

    func setSourceEnabled(_ id: String, enabled: Bool) {
        ensureStarted()
        guard let index = state.sources.firstIndex(where: { $0.id == id }) else { return }
        guard state.sources[index].enabled != enabled else { return }
        state.sources[index].enabled = enabled
        save()
        publish(rulesChanged: false, reloadActive: false)
        if enabled {
            let source = state.sources[index]
            if source.lastUpdated == nil {
                retry(id: id)
            } else if state.blockingEnabled && BlockListUpdateSchedule.isDue(lastUpdated: source.lastUpdated, now: Date()) {
                update(force: false)
            }
        }
        compileIfNeeded(reloadActive: false)
    }

    func setShowBlockedCount(_ shown: Bool) {
        ensureStarted()
        guard state.showBlockedCount != shown else { return }
        state.showBlockedCount = shown
        save()
        publish(rulesChanged: false, reloadActive: false)
    }

    /// Nil when the list was added. The string is a message for Settings.
    func addCustom(url raw: String) -> String? {
        ensureStarted()
        switch BlockListURL.check(raw) {
        case .failure:
            return "Use an https:// address"
        case .success:
            break
        }
        switch BlockListCatalog.addingCustom(url: raw, to: state) {
        case .failure(.duplicate):
            return "This list is already added"
        case .failure:
            return "Use an https:// address"
        case .success(let next):
            state = next
            save()
            publish(rulesChanged: false, reloadActive: false)
            if let id = state.sources.last?.id {
                retry(id: id)
            }
            return nil
        }
    }

    func removeCustom(id: String) {
        ensureStarted()
        guard state.sources.contains(where: { $0.id == id && $0.isBuiltIn == false }) else { return }
        state = BlockListCatalog.removingCustom(id: id, from: state)
        store?.removeCache(id: id)
        save()
        publish(rulesChanged: false, reloadActive: false)
        compileIfNeeded(reloadActive: false)
    }

    func renameCustom(id: String, name: String) {
        ensureStarted()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = state.sources.firstIndex(where: { $0.id == id && $0.isBuiltIn == false }) else { return }
        state.sources[index].name = trimmed
        if state.renamedSourceIDs.contains(id) == false {
            state.renamedSourceIDs.append(id)
        }
        save()
        publish(rulesChanged: false, reloadActive: false)
    }

    func addAllowed(_ raw: String) -> BlockListAllowlist.InsertResult {
        ensureStarted()
        let result = BlockListAllowlist.inserting(raw, into: state.allowlist, now: Date())
        guard case .added(let entries) = result else { return result }
        state.allowlist = entries
        save()
        compileIfNeeded(reloadActive: false, causedByAllowlist: true)
        return result
    }

    /// Removes a paused site and returns it so Settings can offer Undo.
    func removeAllowed(host: String) -> BlockListAllowEntry? {
        ensureStarted()
        guard let name = BlockListAllowlist.normalize(host) else { return nil }
        guard let entry = state.allowlist.first(where: { $0.host == name }) else { return nil }
        state.allowlist.removeAll { $0.host == name }
        save()
        compileIfNeeded(reloadActive: false, causedByAllowlist: true)
        return entry
    }

    func restoreAllowed(_ entry: BlockListAllowEntry) {
        ensureStarted()
        guard let host = BlockListAllowlist.normalize(entry.host) else { return }
        if state.allowlist.contains(where: { $0.host == host }) { return }
        state.allowlist.insert(BlockListAllowEntry(host: host, added: entry.added), at: 0)
        state.allowlist = BlockListAllowlist.normalizedEntries(state.allowlist)
        save()
        compileIfNeeded(reloadActive: false, causedByAllowlist: true)
    }

    /// Downloads one list even when it is not due and the master switch is off.
    func retry(id: String) {
        ensureStarted()
        guard state.sources.contains(where: { $0.id == id }) else { return }
        if isUpdating {
            if pendingRetryIDs.contains(id) == false {
                pendingRetryIDs.append(id)
            }
            pendingFollowUp = true
            return
        }
        isUpdating = true
        publish(rulesChanged: false, reloadActive: false)
        fetch(ids: [id], now: Date(), index: 0)
    }

    func update(force: Bool) {
        ensureStarted()
        if isUpdating {
            if force {
                pendingForce = true
            }
            pendingFollowUp = true
            return
        }
        let now = Date()
        let due = BlockListUpdateSchedule.sourcesToFetch(state: state, now: now, force: force)
        guard !due.isEmpty else { return }
        isUpdating = true
        pendingForce = false
        publish(rulesChanged: false, reloadActive: false)
        fetch(ids: due.map(\.id), now: now, index: 0)
    }

    /// `blocked` true removes the host from the allowlist. On a compile failure the allowlist is restored.
    func setBlocksSite(host: String, blocked: Bool, completion: @escaping (Bool) -> Void) {
        ensureStarted()
        compileDidPublish = false
        guard BlockListAllowlist.normalize(host) != nil else {
            completion(false)
            return
        }
        let previous = state.allowlist
        let next: [BlockListAllowEntry]
        if blocked {
            guard let normalized = BlockListAllowlist.normalize(host) else {
                completion(false)
                return
            }
            next = state.allowlist.filter { $0.host != normalized }
        } else {
            switch BlockListAllowlist.inserting(host, into: state.allowlist, now: Date()) {
            case .added(let entries):
                next = entries
            case .duplicate:
                completion(true)
                return
            case .invalid:
                completion(false)
                return
            }
        }
        if next == previous {
            completion(true)
            return
        }
        state.allowlist = next
        save()
        compileIfNeeded(reloadActive: false, causedByAllowlist: true) { ok in
            completion(ok)
        }
    }

    private func scheduleBlockedSave() {
        guard blockedSavePending == false else { return }
        blockedSavePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.blockedSavePending = false
                self.save()
            }
        }
    }

    private func ensureStarted() {
        if !started {
            start()
        }
    }

    private func save() {
        state = BlockListCatalog.reconcile(state)
        try? store?.save(state)
    }

    private func fetch(ids: [String], now: Date, index: Int) {
        if index >= ids.count {
            finishUpdate()
            return
        }
        let id = ids[index]
        guard let source = state.sources.first(where: { $0.id == id }),
              let url = URL(string: source.urlString),
              url.scheme?.lowercased() == "https" else {
            BlockListIngestor.noteFailure(message: "The list URL is invalid.", sourceID: id, state: &state)
            save()
            publish(rulesChanged: false, reloadActive: false)
            fetch(ids: ids, now: now, index: index + 1)
            return
        }
        let download = BlockListDownload(limit: maxDownloadBytes)
        download.run(url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                BlockListIngestor.noteFailure(message: error.message, sourceID: id, state: &self.state)
                self.save()
                self.publish(rulesChanged: false, reloadActive: false)
                self.fetch(ids: ids, now: now, index: index + 1)
            case .success(let data):
                let cache = self.store
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let text = BlockListController.decodeList(data)
                    switch BlockListIngestor.inspect(text) {
                    case .rejected(let message):
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                BlockListIngestor.noteFailure(message: message, sourceID: id, state: &self.state)
                                self.save()
                                self.publish(rulesChanged: false, reloadActive: false)
                                self.fetch(ids: ids, now: now, index: index + 1)
                            }
                        }
                    case .accepted(let parsed, let title):
                        if let cache {
                            do {
                                try cache.writeDomains(parsed.domains, id: id)
                            } catch {
                                DispatchQueue.main.async {
                                    MainActor.assumeIsolated {
                                        guard let self else { return }
                                        BlockListIngestor.noteFailure(
                                            message: "Could not save the list.",
                                            sourceID: id,
                                            state: &self.state
                                        )
                                        self.save()
                                        self.publish(rulesChanged: false, reloadActive: false)
                                        self.fetch(ids: ids, now: now, index: index + 1)
                                    }
                                }
                                return
                            }
                        }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                if self.state.sources.contains(where: { $0.id == id }) {
                                    try? BlockListIngestor.record(
                                        parsed,
                                        title: title,
                                        sourceID: id,
                                        now: now,
                                        state: &self.state
                                    )
                                }
                                self.save()
                                self.publish(rulesChanged: false, reloadActive: false)
                                self.fetch(ids: ids, now: now, index: index + 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishUpdate() {
        isUpdating = false
        save()
        let force = pendingForce
        let follow = pendingFollowUp
        let extra = pendingRetryIDs
        pendingForce = false
        pendingFollowUp = false
        pendingRetryIDs = []
        compileIfNeeded(reloadActive: false)
        if extra.isEmpty == false {
            isUpdating = true
            if force { pendingForce = true }
            if follow { pendingFollowUp = true }
            publish(rulesChanged: false, reloadActive: false)
            fetch(ids: extra, now: Date(), index: 0)
            return
        }
        if force || follow {
            update(force: force)
        }
    }

    private static func decodeList(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private func compileIfNeeded(
        reloadActive: Bool,
        causedByAllowlist: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        compileGeneration += 1
        let token = compileGeneration
        allowlistCompile = causedByAllowlist
        if reloadActive {
            reloadAfterCompile = true
        }
        if let completion {
            compileWaiters.append(completion)
        }
        let snapshot = state
        let cache = store
        DispatchQueue.global(qos: .userInitiated).async {
            let groups = cache?.enabledDomainGroups(snapshot) ?? []
            let plan = BlockListCompilePlanner.plan(state: snapshot, domainGroups: groups)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token == self.compileGeneration else { return }
                    self.apply(plan, token: token)
                }
            }
        }
    }

    private func apply(_ plan: BlockListCompilePlan, token: Int) {
        guard token == compileGeneration else { return }
        if installedHash == plan.hash, BlockListCompilePlanner.needsCompile(state: state, plan: plan) == false {
            matcher = BlockListMatcher(domains: plan.domainSet, allowlist: Set(plan.allowlist))
            installedAllowlist = state.allowlist
            finishCompile(ok: true, rulesChanged: false)
            return
        }
        guard let ruleStore = WKContentRuleListStore.default() else {
            if plan.chunkCount == 0 {
                matcher = BlockListMatcher(domains: [], allowlist: Set(plan.allowlist))
                installedAllowlist = state.allowlist
                ContentRuleCoordinator.shared.setBlockLists([])
                state.compiledHash = plan.hash
                state.compileError = nil
                state.installedIdentifiers = []
                save()
                installedHash = plan.hash
                finishCompile(ok: true, rulesChanged: true)
            } else {
                failCompile("Content blockers are not available on this Mac.", token: token)
            }
            return
        }
        let identifiers = plan.identifiers
        let canLookup = state.compiledHash == plan.hash
            && state.compileError == nil
            && state.installedIdentifiers == identifiers
            && plan.chunkCount > 0
        if canLookup {
            lookup(plan, token: token, index: 0, found: [], store: ruleStore)
            return
        }
        if plan.chunkCount == 0 {
            commitInstall(lists: [], plan: plan, token: token, store: ruleStore)
            return
        }
        compileChunk(plan, token: token, index: 0, built: [], store: ruleStore)
    }

    private func lookup(
        _ plan: BlockListCompilePlan,
        token: Int,
        index: Int,
        found: [WKContentRuleList],
        store: WKContentRuleListStore
    ) {
        guard token == compileGeneration else { return }
        if index >= plan.chunkCount {
            commitInstall(lists: found, plan: plan, token: token, store: store)
            return
        }
        let identifier = plan.identifiers[index]
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token == self.compileGeneration else { return }
                    guard let list else {
                        self.compileChunk(plan, token: token, index: 0, built: [], store: store)
                        return
                    }
                    self.lookup(plan, token: token, index: index + 1, found: found + [list], store: store)
                }
            }
        }
    }

    private func compileChunk(
        _ plan: BlockListCompilePlan,
        token: Int,
        index: Int,
        built: [WKContentRuleList],
        store: WKContentRuleListStore
    ) {
        guard token == compileGeneration else { return }
        if index >= plan.chunkCount {
            commitInstall(lists: built, plan: plan, token: token, store: store)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let chunk = plan.chunk(at: index)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token == self.compileGeneration else { return }
                    guard let chunk else {
                        self.failCompile("Could not compile the block list.", token: token)
                        return
                    }
                    store.compileContentRuleList(
                        forIdentifier: chunk.identifier,
                        encodedContentRuleList: chunk.json
                    ) { list, error in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard token == self.compileGeneration else { return }
                                guard let list else {
                                    self.failCompile(Self.compileMessage(error), token: token)
                                    return
                                }
                                self.compileChunk(plan, token: token, index: index + 1, built: built + [list], store: store)
                            }
                        }
                    }
                }
            }
        }
    }

    private func commitInstall(
        lists: [WKContentRuleList],
        plan: BlockListCompilePlan,
        token: Int,
        store: WKContentRuleListStore
    ) {
        guard token == compileGeneration else { return }
        let previous = state.installedIdentifiers
        matcher = BlockListMatcher(domains: plan.domainSet, allowlist: Set(plan.allowlist))
        installedAllowlist = state.allowlist
        state.compiledHash = plan.hash
        state.compileError = nil
        state.installedIdentifiers = plan.identifiers
        save()
        installedHash = plan.hash
        ContentRuleCoordinator.shared.setBlockLists(lists)
        removeStale(previous: previous, keeping: Set(state.installedIdentifiers), token: token, store: store)
        finishCompile(ok: true, rulesChanged: true)
    }

    private func failCompile(_ message: String, token: Int) {
        guard token == compileGeneration else { return }
        // Only an allowlist edit is rolled back. A bad list must not discard unrelated pauses.
        if allowlistCompile, state.allowlist != installedAllowlist {
            state.allowlist = installedAllowlist
            matcher.allowlist = Set(installedAllowlist.map(\.host))
        }
        state.compileError = message
        installedHash = nil
        save()
        finishCompile(ok: false, rulesChanged: false)
    }

    private func finishCompile(ok: Bool, rulesChanged: Bool) {
        // A list download still running will compile again. Reload once, after that compile.
        let reload = ok && reloadAfterCompile && isUpdating == false
        if isUpdating == false {
            reloadAfterCompile = false
        }
        let waiters = compileWaiters
        compileWaiters.removeAll()
        compileDidPublish = true
        lastCompileRulesChanged = rulesChanged
        publish(rulesChanged: rulesChanged, reloadActive: reload)
        for waiter in waiters {
            waiter(ok)
        }
    }

    /// Drops `wyvern.blocklist.*` identifiers that this compile did not just install.
    /// Cookie rule identifiers are never removed.
    private func removeStale(
        previous: [String],
        keeping keep: Set<String>,
        token: Int,
        store: WKContentRuleListStore
    ) {
        let prefix = ContentRuleCompiler.identifierPrefix
        var doomed = previous.filter { $0.hasPrefix(prefix) && keep.contains($0) == false }
        let sweep = max(previous.count, keep.count) + 8
        if sweep > 0 {
            for index in 0..<min(sweep, 64) {
                let identifier = "\(prefix)\(index)"
                if keep.contains(identifier) == false {
                    doomed.append(identifier)
                }
            }
        }
        store.getAvailableContentRuleListIdentifiers { identifiers in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token == self.compileGeneration else { return }
                    var ids = doomed
                    for identifier in identifiers ?? [] where identifier.hasPrefix(prefix) && keep.contains(identifier) == false {
                        ids.append(identifier)
                    }
                    for identifier in Set(ids) {
                        store.removeContentRuleList(forIdentifier: identifier) { _ in }
                    }
                }
            }
        }
    }

    private static func compileMessage(_ error: Error?) -> String {
        let fallback = "Could not compile the block list."
        guard let error else { return fallback }
        let raw = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.contains("://") {
            return fallback
        }
        if raw.count <= 160 {
            return raw
        }
        return String(raw.prefix(157)) + "..."
    }

    private func publish(rulesChanged: Bool, reloadActive: Bool) {
        if rulesChanged {
            NotificationCenter.default.post(name: .wyvernBlockRulesDidChange, object: nil)
        }
        NotificationCenter.default.post(
            name: .wyvernBlockListStateDidChange,
            object: nil,
            userInfo: [
                "rulesChanged": rulesChanged,
                "reloadActive": reloadActive
            ]
        )
    }
}

// Newer SDKs mark the redirect completion Sendable. Match that so the optional method is used.
#if compiler(>=6)
typealias BlockListRedirectCompletion = @Sendable (URLRequest?) -> Void
#else
typealias BlockListRedirectCompletion = (URLRequest?) -> Void
#endif

/// One HTTPS GET capped at the byte limit. The final URL must stay https.
private final class BlockListDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let queue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var failure: BlockListFetchError?
    private var origin: URL?
    private var continuation: CheckedContinuation<Result<Data, BlockListFetchError>, Never>?

    init(limit: Int) {
        self.limit = limit
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        super.init()
    }

    func run(_ url: URL, completion: @escaping (Result<Data, BlockListFetchError>) -> Void) {
        Task {
            let result = await run(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(result)
                }
            }
        }
    }

    private func run(_ url: URL) async -> Result<Data, BlockListFetchError> {
        var request = URLRequest(url: url)
        request.timeoutInterval = 180
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppInfo.displayName, forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                self.continuation = continuation
                self.origin = url
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
        }
    }

    private func complete(_ result: Result<Data, BlockListFetchError>) {
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let url = response.url, let origin, BlockListRedirectPolicy.shouldFollow(from: origin, to: url) == false {
            failure = BlockListFetchError(message: "The list URL is invalid.")
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            failure = BlockListFetchError(message: "Couldn't download the list")
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(http.statusCode) else {
            failure = BlockListFetchError(message: "Couldn't download the list (\(http.statusCode))")
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > Int64(limit) {
            failure = BlockListFetchError(message: "List is too large (max 300,000 rules)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        if self.data.count > limit || data.count > limit - self.data.count {
            failure = BlockListFetchError(message: "List is too large (max 300,000 rules)")
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping BlockListRedirectCompletion
    ) {
        guard let origin, BlockListRedirectPolicy.shouldFollow(from: origin, to: request.url) else {
            failure = BlockListFetchError(message: "The list URL is invalid.")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure {
            complete(.failure(failure))
        } else if error != nil {
            complete(.failure(BlockListFetchError(message: "Couldn't download the list")))
        } else {
            complete(.success(data))
        }
    }
}
