// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Unprivileged ICMP echo. Uses `SOCK_DGRAM` / `IPPROTO_ICMP` (and ICMPV6), which
/// does not need a privileged raw socket. Replies are matched on identifier and
/// sequence because a datagram socket can observe echo replies it did not send.
public final class ICMPProber: Prober {
    public let kind: ProbeKind = .icmp
    private let queue = DispatchQueue(label: "\(AppInfo.bundleIdentifier).icmp-probe")
    private let identifier: UInt16
    private var sequence: UInt16 = 0
    private var operation = 0
    private var v4: Int32 = -1
    private var v6: Int32 = -1
    private let lock = NSLock()

    public init(identifier: UInt16? = nil) {
        let fromProcess = UInt16(truncatingIfNeeded: getpid())
        let chosen = identifier ?? fromProcess
        self.identifier = chosen == 0 ? 1 : chosen
    }

    deinit {
        BSDSockets.close(&v4)
        BSDSockets.close(&v6)
    }

    public func prepare() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return openLocked(.v4) || openLocked(.v6)
    }

    public func probe(host: String, timeout: TimeInterval, completion: @escaping (ProbeAttempt) -> Void) {
        lock.lock()
        operation += 1
        let operation = self.operation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else {
                completion(ProbeAttempt(outcome: .cancelled, kind: .icmp))
                return
            }
            completion(self.perform(host: host, timeout: timeout, operation: operation))
        }
    }

    public func cancel() {
        lock.lock()
        operation += 1
        lock.unlock()
    }

    private func perform(host: String, timeout: TimeInterval, operation: Int) -> ProbeAttempt {
        guard current(operation) else {
            return ProbeAttempt(outcome: .cancelled, kind: kind)
        }
        guard let peer = SystemDNS.lookup(host) else {
            return ProbeAttempt(outcome: .sendFailed, kind: kind)
        }
        lock.lock()
        let opened = openLocked(peer.family)
        let fd = peer.family == .v6 ? v6 : v4
        sequence = sequence &+ 1
        if sequence == 0 { sequence = 1 }
        let sequence = self.sequence
        let identifier = self.identifier
        lock.unlock()
        guard opened, fd >= 0 else {
            return ProbeAttempt(outcome: .unavailable, kind: kind)
        }
        guard current(operation) else {
            return ProbeAttempt(outcome: .cancelled, kind: kind)
        }
        let packet = ICMPPackets.echo(
            family: peer.family,
            identifier: identifier,
            sequence: sequence,
            payload: [UInt8](repeating: 0, count: 8)
        )
        let started = DispatchTime.now().uptimeNanoseconds
        guard BSDSockets.send(packet, fd: fd, peer: peer) else {
            return ProbeAttempt(outcome: .sendFailed, kind: kind)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while current(operation) {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            guard BSDSockets.pollIn(fd: fd, timeout: remaining, cancelled: { !self.current(operation) }) else {
                break
            }
            guard let received = BSDSockets.receive(fd: fd) else { continue }
            if ICMPPackets.matchesEchoReply(
                received.bytes,
                family: peer.family,
                identifier: identifier,
                sequence: sequence
            ) {
                let elapsed = DispatchTime.now().uptimeNanoseconds &- started
                let rtt = Double(elapsed) / 1_000_000_000
                let ip = received.peer.ip.isEmpty ? peer.ip : received.peer.ip
                return ProbeAttempt(outcome: .response(rtt: rtt, resolvedIP: ip), kind: kind)
            }
        }
        if !current(operation) {
            return ProbeAttempt(outcome: .cancelled, kind: kind)
        }
        return ProbeAttempt(outcome: .timeout(resolvedIP: peer.ip), kind: kind)
    }

    private func openLocked(_ family: IPFamily) -> Bool {
        switch family {
        case .v4:
            if v4 >= 0 { return true }
            v4 = BSDSockets.openICMPReceive(.v4)
            return v4 >= 0
        case .v6:
            if v6 >= 0 { return true }
            v6 = BSDSockets.openICMPReceive(.v6)
            return v6 >= 0
        }
    }

    private func current(_ operation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.operation == operation
    }
}
