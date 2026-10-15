// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Rolling in-memory window. Samples older than `duration` drop out.
/// Nothing here is written to disk.
public struct HealthWindow: Equatable, Sendable {
    public let duration: TimeInterval
    private var samples: [HealthSample]

    public init(duration: TimeInterval = HealthLimits.windowDuration) {
        self.duration = duration
        self.samples = []
    }

    public mutating func add(_ sample: HealthSample, now: Date) {
        samples.append(sample)
        expire(now: now)
    }

    /// A sample leaves when its age is greater than or equal to `duration`.
    public mutating func expire(now: Date) {
        samples.removeAll { now.timeIntervalSince($0.timestamp) >= duration }
    }

    public func samples(at now: Date) -> [HealthSample] {
        samples
            .filter { now.timeIntervalSince($0.timestamp) < duration }
            .sorted { $0.timestamp < $1.timestamp }
    }

    public func stats(at now: Date) -> HealthStats {
        HealthStats.compute(from: samples(at: now))
    }

    /// Puts a pane's saved samples back so a focus change does not start from an empty window.
    public mutating func restore(_ samples: [HealthSample], now: Date) {
        self.samples = samples
        expire(now: now)
    }
}
