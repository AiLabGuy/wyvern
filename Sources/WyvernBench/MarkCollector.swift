// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
import WyvernCore

struct BenchMarkEvent {
    var name: String
    var nanoseconds: UInt64
}

/// Thread-safe parser for `BENCH_MARK <name> <monotonic ns>` lines on the app's stdout.
final class MarkCollector {
    private let lock = NSLock()
    private var pending = Data()
    private var events: [BenchMarkEvent] = []

    func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pending.append(data)
        while let range = pending.range(of: Data([0x0A])) {
            let lineData = pending.subdata(in: pending.startIndex..<range.lowerBound)
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8) {
                parseLocked(line)
            }
        }
        lock.unlock()
    }

    func snapshot() -> [BenchMarkEvent] {
        lock.lock()
        let copy = events
        lock.unlock()
        return copy
    }

    func first(name: String, after start: UInt64) -> UInt64? {
        for event in snapshot() where event.name == name && event.nanoseconds >= start {
            return event.nanoseconds
        }
        return nil
    }

    func wait(name: String, after start: UInt64, timeout: TimeInterval) -> UInt64? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ns = first(name: name, after: start) {
                return ns
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return first(name: name, after: start)
    }

    private func parseLocked(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == BenchMarks.prefix else { return }
        let name = String(parts[1])
        guard let ns = UInt64(parts[2]) else { return }
        events.append(BenchMarkEvent(name: name, nanoseconds: ns))
    }
}
