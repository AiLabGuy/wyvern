// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct TraceHop: Equatable, Sendable {
    public var ttl: Int
    public var ip: String?
    public var rtt: TimeInterval?

    public init(ttl: Int, ip: String?, rtt: TimeInterval?) {
        self.ttl = ttl
        self.ip = ip
        self.rtt = rtt
    }
}

public enum TraceError: Equatable, Sendable {
    /// The unprivileged ICMP datagram socket could not be opened, so time-exceeded
    /// messages cannot be read. This is not a guess about the path.
    case receiveUnavailable
    case hostDidNotResolve
    case noCurrentHost

    public var message: String {
        switch self {
        case .receiveUnavailable:
            return "Unprivileged ICMP receive is not available."
        case .hostDidNotResolve:
            return "The host did not resolve."
        case .noCurrentHost:
            return "There is no current host to trace."
        }
    }
}

public enum TracerouteResult: Equatable, Sendable {
    case hops([TraceHop])
    case unavailable(TraceError)
    case cancelled
}

enum HopReply: Equatable {
    case timeExceeded(ip: String, rtt: TimeInterval)
    case reached(ip: String, rtt: TimeInterval)
    case timeout
    case sendFailed
}

/// Lookup, receive-socket, and one-hop send used by `Traceroute`.
/// Production wires these to BSD sockets. Tests pass fakes so no packet is sent.
struct TraceDriver {
    var lookup: (String) -> ResolvedPeer?
    var prepare: (IPFamily) -> TraceError?
    var close: () -> Void
    var probe: (_ ttl: Int, _ port: UInt16, _ timeout: TimeInterval, _ peer: ResolvedPeer) -> HopReply

    static func live(stop: @escaping () -> Bool) -> TraceDriver {
        let ports = LiveTracePorts(stop: stop)
        return TraceDriver(
            lookup: { SystemDNS.lookup($0) },
            prepare: { ports.prepare($0) },
            close: { ports.close() },
            probe: { ttl, port, timeout, peer in
                ports.probe(ttl: ttl, port: port, timeout: timeout, peer: peer)
            }
        )
    }
}

/// On-demand UDP traceroute. Each hop is a new UDP socket with `IP_TTL` set once.
/// A reused socket can emit every datagram with the last TTL, because the option
/// is applied when the datagram leaves the send queue.
///
/// ICMP time-exceeded is read on an unprivileged `SOCK_DGRAM` ICMP socket.
/// If that socket cannot be opened, the result is `.unavailable(.receiveUnavailable)`
/// and no probe is sent.
public final class Traceroute {
    private let driver: TraceDriver
    private let queue = DispatchQueue(label: "\(AppInfo.bundleIdentifier).traceroute")
    private let flag: CancelFlag

    public init() {
        let flag = CancelFlag()
        self.flag = flag
        self.driver = .live(stop: { flag.value })
    }

    init(driver: TraceDriver) {
        self.flag = CancelFlag()
        self.driver = driver
    }

    public func run(
        host: String,
        maxHops: Int = HealthLimits.traceMaxHops,
        perHopTimeout: TimeInterval = HealthLimits.traceHopTimeout,
        completion: @escaping (TracerouteResult) -> Void
    ) {
        flag.value = false
        queue.async { [weak self] in
            guard let self else {
                completion(.cancelled)
                return
            }
            completion(self.execute(host: host, maxHops: maxHops, perHopTimeout: perHopTimeout))
        }
    }

    public func cancel() {
        flag.value = true
    }

    func execute(host: String, maxHops: Int, perHopTimeout: TimeInterval) -> TracerouteResult {
        if flag.value { return .cancelled }
        guard let peer = driver.lookup(host) else {
            return .unavailable(.hostDidNotResolve)
        }
        if let failure = driver.prepare(peer.family) {
            driver.close()
            return .unavailable(failure)
        }
        defer { driver.close() }
        let limit = min(max(maxHops, 0), HealthLimits.traceMaxHops)
        guard limit > 0 else { return .hops([]) }
        var hops: [TraceHop] = []
        for ttl in 1...limit {
            if flag.value { return .cancelled }
            let port = UInt16(HealthLimits.traceBasePort + ttl - 1)
            let reply = driver.probe(ttl, port, perHopTimeout, peer)
            if flag.value { return .cancelled }
            switch reply {
            case .timeExceeded(let ip, let rtt):
                hops.append(TraceHop(ttl: ttl, ip: ip.isEmpty ? nil : ip, rtt: rtt))
            case .reached(let ip, let rtt):
                hops.append(TraceHop(ttl: ttl, ip: ip.isEmpty ? nil : ip, rtt: rtt))
                return .hops(hops)
            case .timeout, .sendFailed:
                hops.append(TraceHop(ttl: ttl, ip: nil, rtt: nil))
            }
        }
        return .hops(hops)
    }
}

private final class CancelFlag {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// Real hop I/O. Not used by tests.
final class LiveTracePorts {
    private let stop: () -> Bool
    private var icmp: Int32 = -1
    private var family: IPFamily = .v4

    init(stop: @escaping () -> Bool) {
        self.stop = stop
    }

    deinit {
        BSDSockets.close(&icmp)
    }

    func prepare(_ family: IPFamily) -> TraceError? {
        self.family = family
        BSDSockets.close(&icmp)
        icmp = BSDSockets.openICMPReceive(family)
        if icmp < 0 {
            return .receiveUnavailable
        }
        return nil
    }

    func close() {
        BSDSockets.close(&icmp)
    }

    func probe(ttl: Int, port: UInt16, timeout: TimeInterval, peer: ResolvedPeer) -> HopReply {
        guard icmp >= 0 else { return .sendFailed }
        let udp = BSDSockets.openUDP(peer.family)
        guard udp >= 0 else { return .sendFailed }
        defer {
            var fd = udp
            BSDSockets.close(&fd)
        }
        // One socket per hop so this TTL cannot be overwritten by the next hop's option.
        guard BSDSockets.setTTL(Int32(ttl), fd: udp, family: peer.family) else {
            return .sendFailed
        }
        let destination = peer.withPort(port)
        let payload = [UInt8](repeating: 0, count: 12)
        let started = DispatchTime.now().uptimeNanoseconds
        guard BSDSockets.send(payload, fd: udp, peer: destination) else {
            return .sendFailed
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !stop() {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timeout }
            guard BSDSockets.pollIn(fd: icmp, timeout: remaining, cancelled: stop) else {
                return .timeout
            }
            guard let received = BSDSockets.receive(fd: icmp) else { continue }
            guard let quote = ICMPPackets.errorQuote(received.bytes, family: peer.family) else { continue }
            guard quote.destinationPort == port else { continue }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            let rtt = Double(elapsed) / 1_000_000_000
            switch quote.kind {
            case .timeExceeded:
                return .timeExceeded(ip: received.peer.ip, rtt: rtt)
            case .portUnreachable:
                return .reached(ip: received.peer.ip, rtt: rtt)
            case .other:
                continue
            }
        }
        return .timeout
    }
}
