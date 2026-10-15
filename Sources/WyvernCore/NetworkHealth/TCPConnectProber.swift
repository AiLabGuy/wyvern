// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Network

/// Times a TCP handshake to `port` and cancels as soon as the connection is ready.
/// Port 443 is the usual choice. Port 80 is used for an `http` scheme. No request is sent.
public final class TCPConnectProber: Prober {
    public let kind: ProbeKind
    private let port: UInt16
    private let queue = DispatchQueue(label: "\(AppInfo.bundleIdentifier).tcp-probe")
    private var connection: NWConnection?
    private var onFinish: ((ProbeAttempt) -> Void)?
    private var generation = 0
    private var finished = false
    private let lock = NSLock()

    public init(port: UInt16) {
        self.port = port
        self.kind = .tcp(port: port)
    }

    public func prepare() -> Bool {
        port > 0
    }

    public func probe(host: String, timeout: TimeInterval, completion: @escaping (ProbeAttempt) -> Void) {
        queue.async { [weak self] in
            self?.start(host: host, timeout: timeout, completion: completion)
        }
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            let token = self.currentGeneration()
            self.complete(.cancelled, token: token)
        }
    }

    private func start(host: String, timeout: TimeInterval, completion: @escaping (ProbeAttempt) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(ProbeAttempt(outcome: .unavailable, kind: kind))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        lock.lock()
        generation += 1
        let token = generation
        finished = false
        onFinish = completion
        self.connection = connection
        lock.unlock()
        let started = DispatchTime.now().uptimeNanoseconds

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                let elapsed = DispatchTime.now().uptimeNanoseconds &- started
                let rtt = Double(elapsed) / 1_000_000_000
                self.complete(.response(rtt: rtt, resolvedIP: nil), token: token)
            case .waiting(_):
                if connection.currentPath?.status == .unsatisfied {
                    self.complete(.noRoute, token: token)
                }
            case .failed(_):
                self.complete(.timeout(resolvedIP: nil), token: token)
            case .cancelled:
                self.complete(.cancelled, token: token)
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.complete(.timeout(resolvedIP: nil), token: token)
        }
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func complete(_ outcome: ProbeOutcome, token: Int) {
        lock.lock()
        guard token == generation, finished == false else {
            lock.unlock()
            return
        }
        finished = true
        let handler = onFinish
        onFinish = nil
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        handler?(ProbeAttempt(outcome: outcome, kind: kind))
    }
}
