// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How the current host is being measured. The panel shows `displayName`.
public enum ProbeKind: Equatable, Sendable {
    case icmp
    case tcp(port: UInt16)

    public var displayName: String {
        switch self {
        case .icmp:
            return "ICMP echo"
        case .tcp(let port):
            return "TCP connect :\(port)"
        }
    }
}

public enum ProbeOutcome: Equatable, Sendable {
    /// Echo reply or a TCP handshake reached `.ready`.
    case response(rtt: TimeInterval, resolvedIP: String?)
    /// The send was attempted and nothing usable came back before the timeout.
    case timeout(resolvedIP: String?)
    /// `send` failed, or the TCP stack refused the attempt before a handshake.
    /// These count toward the ICMP-to-TCP fallback. A timeout does not.
    case sendFailed
    /// The socket could not be opened.
    case unavailable
    /// The system reports no route to the host.
    case noRoute
    case cancelled
}

public struct ProbeAttempt: Equatable, Sendable {
    public var outcome: ProbeOutcome
    public var kind: ProbeKind

    public init(outcome: ProbeOutcome, kind: ProbeKind) {
        self.outcome = outcome
        self.kind = kind
    }
}

/// One probe transport. Implementations must call `completion` exactly once
/// and must not contact any host other than the one they were given.
public protocol Prober: AnyObject {
    var kind: ProbeKind { get }
    /// Returns false when the transport cannot be opened, before any packet is sent.
    func prepare() -> Bool
    func probe(host: String, timeout: TimeInterval, completion: @escaping (ProbeAttempt) -> Void)
    func cancel()
}

public func tcpPort(forScheme scheme: String) -> UInt16 {
    scheme.lowercased() == "http" ? 80 : 443
}

/// Clock and scheduler for the service. Tests advance time without sleeping.
public protocol HealthClock: AnyObject {
    var now: Date { get }
    @discardableResult
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> any HealthCancellable
}

public protocol HealthCancellable: AnyObject {
    func cancel()
}

public final class DispatchHealthClock: HealthClock {
    public var now: Date { Date() }
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> any HealthCancellable {
        let work = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + delay, execute: work)
        return DispatchCancelBox(work: work)
    }
}

private final class DispatchCancelBox: HealthCancellable {
    private let work: DispatchWorkItem

    init(work: DispatchWorkItem) {
        self.work = work
    }

    func cancel() {
        work.cancel()
    }
}

/// IP string for the snapshot. Production uses `getaddrinfo`. Tests supply a fake.
public protocol HostResolving: AnyObject {
    func resolve(_ host: String) -> String?
}

public final class SystemHostResolver: HostResolving {
    public init() {}

    public func resolve(_ host: String) -> String? {
        SystemDNS.lookup(host)?.ip
    }
}
