// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One published view of the current host. The badge and the monitor panel both read this.
/// `protocolName` stays nil until the tab reports the negotiated protocol.
/// Samples live only in this value. They are not stored on disk and are not sent anywhere.
public struct NetworkHealthSnapshot: Equatable, Sendable {
    public var host: String
    public var scheme: String
    public var state: HealthState
    public var stats: HealthStats
    public var samples: [HealthSample]
    public var presentation: HealthPresentation
    public var probeKind: ProbeKind?
    public var resolvedIP: String?
    public var protocolName: String?
    public var enabled: Bool
    public var probing: Bool
    /// Nil until a trace finishes with hops. The panel shows a dash for nil.
    public var hopCount: Int?
    /// True only when the state just became poor or offline.
    public var announcePolitely: Bool
    public var accessibilityLabel: String

    public init(
        host: String,
        scheme: String,
        state: HealthState,
        stats: HealthStats,
        samples: [HealthSample],
        presentation: HealthPresentation,
        probeKind: ProbeKind?,
        resolvedIP: String?,
        protocolName: String?,
        enabled: Bool,
        probing: Bool,
        hopCount: Int?,
        announcePolitely: Bool,
        accessibilityLabel: String
    ) {
        self.host = host
        self.scheme = scheme
        self.state = state
        self.stats = stats
        self.samples = samples
        self.presentation = presentation
        self.probeKind = probeKind
        self.resolvedIP = resolvedIP
        self.protocolName = protocolName
        self.enabled = enabled
        self.probing = probing
        self.hopCount = hopCount
        self.announcePolitely = announcePolitely
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Probes the visible tab's host about once a second and publishes a snapshot on the main queue.
///
/// The feature has one `enabled` flag for the whole service. A later settings toggle binds to it.
/// After `visibilityChanged(visible: false)`, probing continues for `HealthLimits.visibilityGrace`
/// seconds and then stops. Nothing is contacted except the current host.
public final class NetworkHealthService {
    public var onSnapshot: ((NetworkHealthSnapshot) -> Void)?

    public var enabled: Bool {
        get {
            mutex.lock()
            defer { mutex.unlock() }
            return storedEnabled
        }
        set {
            mutex.lock()
            let changed = storedEnabled != newValue
            storedEnabled = newValue
            if !newValue {
                generation += 1
                scheduled?.cancel()
                scheduled = nil
                inFlight = false
                confirming = false
                probing = false
            }
            let resume = newValue && changed && shouldProbeLocked(now: clock.now)
            mutex.unlock()
            guard changed else { return }
            if !newValue {
                icmp.cancel()
                tcp?.cancel()
                publish()
            } else if resume {
                probeNow()
            } else {
                publish()
            }
        }
    }

    /// Negotiated protocol reported by the tab, such as "HTTP/2". Nil until that exists.
    public var protocolName: String? {
        get {
            mutex.lock()
            defer { mutex.unlock() }
            return storedProtocol
        }
        set {
            mutex.lock()
            storedProtocol = newValue
            mutex.unlock()
            publish()
        }
    }

    public var currentSnapshot: NetworkHealthSnapshot {
        mutex.lock()
        defer { mutex.unlock() }
        return storedSnapshot
    }

    private let clock: any HealthClock
    private let icmp: any Prober
    private let tcpFactory: (UInt16) -> any Prober
    private let resolver: any HostResolving
    private let deliver: (@escaping () -> Void) -> Void
    private let traceroute: Traceroute
    private let mutex = NSLock()
    private var machine: HealthStateMachine
    private var storedEnabled: Bool
    private var hostKey = ""
    private var schemeKey = ""
    private var visible = true
    private var hiddenAt: Date?
    private var generation = 0
    private var inFlight = false
    private var confirming = false
    private var scheduled: (any HealthCancellable)?
    private var active: any Prober
    private var tcp: (any Prober)?
    private var usingTCP = false
    private var icmpFailures = 0
    private var resolvedIP: String?
    private var storedProtocol: String?
    private var probeKind: ProbeKind?
    private var probing = false
    private var hopCount: Int?
    private var lastPublished: HealthState?
    private var storedSnapshot: NetworkHealthSnapshot

    public init(
        clock: any HealthClock = DispatchHealthClock(),
        icmp: any Prober = ICMPProber(),
        tcpFactory: @escaping (UInt16) -> any Prober = { TCPConnectProber(port: $0) },
        resolver: any HostResolving = SystemHostResolver(),
        traceroute: Traceroute = Traceroute(),
        enabled: Bool = true,
        deliver: @escaping (@escaping () -> Void) -> Void = NetworkHealthService.deliverOnMain
    ) {
        self.clock = clock
        self.icmp = icmp
        self.tcpFactory = tcpFactory
        self.resolver = resolver
        self.traceroute = traceroute
        self.deliver = deliver
        self.storedEnabled = enabled
        self.active = icmp
        let clockBox = clock
        self.machine = HealthStateMachine(clock: { clockBox.now })
        self.storedSnapshot = NetworkHealthSnapshot(
            host: "",
            scheme: "",
            state: .unknown,
            stats: .empty,
            samples: [],
            presentation: HealthState.unknown.presentation,
            probeKind: nil,
            resolvedIP: nil,
            protocolName: nil,
            enabled: enabled,
            probing: false,
            hopCount: nil,
            announcePolitely: false,
            accessibilityLabel: HealthState.unknown.accessibilityLabel(host: "", medianRTT: nil)
        )
    }

    deinit {
        scheduled?.cancel()
        icmp.cancel()
        tcp?.cancel()
        traceroute.cancel()
    }

    /// Runs the block on the main queue. Inline when the caller is already there.
    public static func deliverOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    public func start(host: String, scheme: String, restoring remembered: NetworkHealthSnapshot? = nil) {
        let key = Self.normalize(host)
        mutex.lock()
        let hostChanged = key != hostKey || scheme.lowercased() != schemeKey
        let loopRunning = probing && (inFlight || scheduled != nil || confirming)
        hostKey = key
        schemeKey = scheme.lowercased()
        visible = true
        hiddenAt = nil
        if hostChanged {
            generation += 1
            scheduled?.cancel()
            scheduled = nil
            inFlight = false
            confirming = false
            icmpFailures = 0
            hopCount = nil
            storedProtocol = nil
            resolvedIP = nil
            probeKind = nil
            lastPublished = nil
            machine.reset()
            if !key.isEmpty {
                machine.begin(at: clock.now)
            }
            if let remembered,
               Self.normalize(remembered.host) == key,
               remembered.scheme.lowercased() == scheme.lowercased(),
               !key.isEmpty {
                machine.restore(state: remembered.state, samples: remembered.samples, at: clock.now)
                probeKind = remembered.probeKind
                resolvedIP = remembered.resolvedIP
                storedProtocol = remembered.protocolName
                hopCount = remembered.hopCount
                lastPublished = remembered.state
            }
            installProberLocked()
        }
        let should = shouldProbeLocked(now: clock.now)
        let already = !hostChanged && loopRunning
        mutex.unlock()
        if hostChanged {
            icmp.cancel()
            tcp?.cancel()
            traceroute.cancel()
        }
        if should && !already {
            probeNow()
        } else {
            publish()
        }
    }

    public func stop() {
        mutex.lock()
        generation += 1
        scheduled?.cancel()
        scheduled = nil
        inFlight = false
        confirming = false
        probing = false
        hostKey = ""
        schemeKey = ""
        visible = true
        hiddenAt = nil
        hopCount = nil
        storedProtocol = nil
        resolvedIP = nil
        probeKind = nil
        icmpFailures = 0
        usingTCP = false
        active = icmp
        machine.reset()
        mutex.unlock()
        icmp.cancel()
        tcp?.cancel()
        traceroute.cancel()
        publish()
    }

    /// The visible tab gained or lost focus. Probing continues for about 30 seconds after it is hidden.
    public func visibilityChanged(visible: Bool) {
        mutex.lock()
        self.visible = visible
        if visible {
            hiddenAt = nil
        } else if hiddenAt == nil {
            hiddenAt = clock.now
        }
        let resume = visible && shouldProbeLocked(now: clock.now) && !inFlight && scheduled == nil && !confirming
        mutex.unlock()
        if resume {
            probeNow()
        } else {
            publish()
        }
    }

    public func trace(completion: @escaping (TracerouteResult) -> Void) {
        mutex.lock()
        let host = hostKey
        mutex.unlock()
        guard !host.isEmpty else {
            let result = TracerouteResult.unavailable(.noCurrentHost)
            deliver { completion(result) }
            return
        }
        traceroute.run(host: host) { [weak self] result in
            guard let self else {
                completion(result)
                return
            }
            self.mutex.lock()
            switch result {
            case .hops(let hops):
                self.hopCount = hops.count
            case .unavailable:
                self.hopCount = nil
            case .cancelled:
                break
            }
            self.mutex.unlock()
            self.publish()
            self.deliver { completion(result) }
        }
    }

    public func cancelTrace() {
        traceroute.cancel()
    }

    static func normalize(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") {
            host.removeLast()
        }
        if host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 {
            host.removeFirst()
            host.removeLast()
        }
        if let colon = host.firstIndex(of: ":"), host.lastIndex(of: ":") == colon {
            let port = host[host.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy(\.isNumber) {
                host = String(host[..<colon])
            }
        }
        return host
    }

    private func installProberLocked() {
        if icmp.prepare() {
            active = icmp
            usingTCP = false
        } else {
            let next = tcpFactory(tcpPort(forScheme: schemeKey))
            tcp = next
            active = next
            usingTCP = true
            probeKind = next.kind
        }
    }

    private func shouldProbeLocked(now: Date) -> Bool {
        guard storedEnabled, !hostKey.isEmpty else { return false }
        if visible { return true }
        guard let hiddenAt else { return true }
        return now.timeIntervalSince(hiddenAt) < HealthLimits.visibilityGrace
    }

    private func probeNow() {
        mutex.lock()
        let now = clock.now
        guard shouldProbeLocked(now: now), !inFlight, !confirming else {
            if !shouldProbeLocked(now: now) {
                probing = false
            }
            mutex.unlock()
            publish()
            return
        }
        let host = hostKey
        let prober = active
        let token = generation
        inFlight = true
        probing = true
        mutex.unlock()
        let timeout = HealthLimits.probeTimeout
        prober.probe(host: host, timeout: timeout) { [weak self] attempt in
            self?.handle(attempt, token: token, started: now, host: host)
        }
    }

    private func handle(_ attempt: ProbeAttempt, token: Int, started: Date, host: String) {
        let lookedUp = resolver.resolve(host)
        mutex.lock()
        guard token == generation, host == hostKey else {
            mutex.unlock()
            return
        }
        inFlight = false
        if let lookedUp {
            resolvedIP = lookedUp
        } else if let discovered = Self.ip(from: attempt.outcome) {
            resolvedIP = discovered
        }
        let now = clock.now
        switch attempt.outcome {
        case .cancelled:
            mutex.unlock()
            return
        case .noRoute:
            probeKind = attempt.kind
            machine.noteNoRoute(at: now)
            mutex.unlock()
            publish()
            scheduleNext(token: token, started: started)
        case .response(let rtt, _):
            if !usingTCP {
                icmpFailures = 0
            }
            probeKind = attempt.kind
            machine.record(rtt: rtt, lost: false, at: now)
            mutex.unlock()
            publish()
            scheduleNext(token: token, started: started)
        case .timeout:
            if !usingTCP {
                icmpFailures = 0
            }
            probeKind = attempt.kind
            machine.record(rtt: nil, lost: true, at: now)
            mutex.unlock()
            publish()
            scheduleNext(token: token, started: started)
        case .sendFailed:
            let switchNow = !usingTCP && isICMP(attempt.kind) && noteICMPSendFailureLocked()
            if switchNow {
                let port = tcpPort(forScheme: schemeKey)
                confirming = true
                mutex.unlock()
                confirmTCP(port: port, token: token, started: started, host: host)
            } else {
                _ = machine.advance(to: now)
                mutex.unlock()
                publish()
                scheduleNext(token: token, started: started)
            }
        case .unavailable:
            if !usingTCP && isICMP(attempt.kind) {
                let port = tcpPort(forScheme: schemeKey)
                icmpFailures = 0
                confirming = true
                mutex.unlock()
                confirmTCP(port: port, token: token, started: started, host: host)
            } else {
                probeKind = attempt.kind
                machine.record(rtt: nil, lost: true, at: now)
                mutex.unlock()
                publish()
                scheduleNext(token: token, started: started)
            }
        }
    }

    /// Returns true when this failure is the one that should try TCP.
    private func noteICMPSendFailureLocked() -> Bool {
        icmpFailures += 1
        if icmpFailures >= HealthLimits.icmpFailuresBeforeFallback {
            icmpFailures = 0
            return true
        }
        return false
    }

    private func confirmTCP(port: UInt16, token: Int, started: Date, host: String) {
        let candidate = tcpFactory(port)
        candidate.probe(host: host, timeout: HealthLimits.probeTimeout) { [weak self] attempt in
            guard let self else { return }
            let lookedUp = self.resolver.resolve(host)
            self.mutex.lock()
            guard token == self.generation, host == self.hostKey else {
                self.confirming = false
                self.mutex.unlock()
                return
            }
            self.confirming = false
            if let lookedUp {
                self.resolvedIP = lookedUp
            }
            let now = self.clock.now
            let accepted: Bool
            if case .response = attempt.outcome {
                accepted = true
            } else {
                accepted = false
            }
            if accepted {
                self.usingTCP = true
                self.tcp = candidate
                self.active = candidate
                self.probeKind = candidate.kind
            } else {
                self.probeKind = self.active.kind
            }
            switch attempt.outcome {
            case .response(let rtt, _):
                self.machine.record(rtt: rtt, lost: false, at: now)
            case .timeout, .unavailable:
                self.machine.record(rtt: nil, lost: true, at: now)
            case .noRoute:
                self.machine.noteNoRoute(at: now)
            case .sendFailed:
                _ = self.machine.advance(to: now)
            case .cancelled:
                self.mutex.unlock()
                return
            }
            self.mutex.unlock()
            self.publish()
            self.scheduleNext(token: token, started: started)
        }
    }

    private func scheduleNext(token: Int, started: Date) {
        let elapsed = clock.now.timeIntervalSince(started)
        let delay = max(0, HealthLimits.probeInterval - elapsed)
        mutex.lock()
        guard token == generation, shouldProbeLocked(now: clock.now) else {
            probing = false
            scheduled?.cancel()
            scheduled = nil
            mutex.unlock()
            publish()
            return
        }
        scheduled?.cancel()
        mutex.unlock()
        let box = clock.schedule(after: delay) { [weak self] in
            self?.scheduledFired(token: token)
        }
        mutex.lock()
        if token != generation {
            mutex.unlock()
            box.cancel()
            return
        }
        scheduled = box
        mutex.unlock()
    }

    private func scheduledFired(token: Int) {
        mutex.lock()
        if token != generation {
            mutex.unlock()
            return
        }
        scheduled = nil
        mutex.unlock()
        probeNow()
    }

    private func publish() {
        let snapshot = makeSnapshot()
        deliver { [weak self] in
            self?.onSnapshot?(snapshot)
        }
    }

    private func makeSnapshot() -> NetworkHealthSnapshot {
        mutex.lock()
        defer { mutex.unlock() }
        let reading = machine.reading(at: clock.now)
        let announce = lastPublished != reading.state && reading.state.announcesStateChangePolitely
        lastPublished = reading.state
        let snapshot = NetworkHealthSnapshot(
            host: hostKey,
            scheme: schemeKey,
            state: reading.state,
            stats: reading.stats,
            samples: reading.samples,
            presentation: reading.presentation,
            probeKind: probeKind,
            resolvedIP: resolvedIP,
            protocolName: storedProtocol,
            enabled: storedEnabled,
            probing: probing,
            hopCount: hopCount,
            announcePolitely: announce,
            accessibilityLabel: reading.state.accessibilityLabel(
                host: hostKey,
                medianRTT: reading.stats.medianRTT
            )
        )
        storedSnapshot = snapshot
        return snapshot
    }

    private func isICMP(_ kind: ProbeKind) -> Bool {
        if case .icmp = kind { return true }
        return false
    }

    private static func ip(from outcome: ProbeOutcome) -> String? {
        switch outcome {
        case .response(_, let ip), .timeout(let ip):
            return ip
        case .sendFailed, .unavailable, .noRoute, .cancelled:
            return nil
        }
    }
}
