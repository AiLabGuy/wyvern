// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Limits from the vitals-monitor spec. Times stored on samples are seconds;
/// the comparisons below are in whole milliseconds so 80 and 250 do not drift.
public enum HealthLimits {
    /// p50 RTT below this is good when loss and jitter are also inside their limits.
    public static let goodUpperMilliseconds = 80
    /// p50 RTT at or below this (and at or above `goodUpperMilliseconds`) is fair.
    public static let fairUpperMilliseconds = 250
    /// Loss above this percent is poor. Exactly 2 is not poor.
    public static let lossPoorPercent = 2.0
    /// Mean absolute successive RTT difference above this is poor. Exactly 100 is not.
    public static let jitterPoorMilliseconds = 100
    public static let offlineSilence: TimeInterval = 3
    public static let samplesToCommit = 2
    public static let windowDuration: TimeInterval = 60
    public static let probeInterval: TimeInterval = 1
    public static let probeTimeout: TimeInterval = 0.9
    public static let visibilityGrace: TimeInterval = 30
    public static let icmpFailuresBeforeFallback = 3
    public static let traceMaxHops = 30
    public static let traceHopTimeout: TimeInterval = 1
    public static let traceBasePort = 33_434
    public static let colorCrossfade: TimeInterval = 0.2
}

/// Connection quality for the host of the visible tab.
/// `unknown` is the idle state before two samples have agreed.
public enum HealthState: String, Equatable, Sendable, CaseIterable {
    case unknown
    case good
    case fair
    case poor
    case offline

    /// Short badge text. Empty only when there is nothing to say; idle uses IDLE.
    public var label: String {
        switch self {
        case .unknown: return "IDLE"
        case .good: return "GOOD"
        case .fair: return "FAIR"
        case .poor: return "POOR"
        case .offline: return "OFFLINE"
        }
    }

    /// Spoken form used in the accessibility label.
    public var spokenName: String {
        switch self {
        case .unknown: return "Unknown"
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        case .offline: return "Offline"
        }
    }

    /// Shape the badge draws itself: circle, triangle, cross, dash, or none.
    public var glyphName: String {
        switch self {
        case .unknown: return "none"
        case .good: return "circle"
        case .fair: return "triangle"
        case .poor: return "cross"
        case .offline: return "dash"
        }
    }

    /// Waveform id. The shape changes on the next beat; the UI does not invent its own.
    public var beatShapeID: String {
        switch self {
        case .unknown: return "idle"
        case .good: return "sharp-qrs"
        case .fair: return "wide-stretched"
        case .poor: return "jagged-spike"
        case .offline: return "flatline"
        }
    }

    public var presentation: HealthPresentation {
        switch self {
        case .unknown:
            return HealthPresentation(
                state: self,
                label: label,
                glyphName: glyphName,
                beatShapeID: beatShapeID,
                beatsPerMinute: 0,
                beatWidthScale: 1,
                intervalJitterFraction: 0,
                beatHeightJitterFraction: 0,
                barSweepPointsPerSecond: 0,
                panelSweepPointsPerSecond: 0,
                headPulseHertz: 0,
                lightHex: "#6E6E6E",
                darkHex: "#8A8A8A"
            )
        case .good:
            return HealthPresentation(
                state: self,
                label: label,
                glyphName: glyphName,
                beatShapeID: beatShapeID,
                beatsPerMinute: 60,
                beatWidthScale: 1,
                intervalJitterFraction: 0,
                beatHeightJitterFraction: 0,
                barSweepPointsPerSecond: 25,
                panelSweepPointsPerSecond: 50,
                headPulseHertz: 0,
                lightHex: "#14834A",
                darkHex: "#3DD68C"
            )
        case .fair:
            return HealthPresentation(
                state: self,
                label: label,
                glyphName: glyphName,
                beatShapeID: beatShapeID,
                beatsPerMinute: 40,
                beatWidthScale: 1.5,
                intervalJitterFraction: 0,
                beatHeightJitterFraction: 0,
                barSweepPointsPerSecond: 25,
                panelSweepPointsPerSecond: 50,
                headPulseHertz: 0,
                lightHex: "#9A6A00",
                darkHex: "#F2C14E"
            )
        case .poor:
            return HealthPresentation(
                state: self,
                label: label,
                glyphName: glyphName,
                beatShapeID: beatShapeID,
                beatsPerMinute: 150,
                beatWidthScale: 1,
                intervalJitterFraction: 0.30,
                beatHeightJitterFraction: 0.30,
                barSweepPointsPerSecond: 40,
                panelSweepPointsPerSecond: 40,
                headPulseHertz: 0,
                lightHex: "#C62828",
                darkHex: "#FF6B6B"
            )
        case .offline:
            return HealthPresentation(
                state: self,
                label: label,
                glyphName: glyphName,
                beatShapeID: beatShapeID,
                beatsPerMinute: 0,
                beatWidthScale: 1,
                intervalJitterFraction: 0,
                beatHeightJitterFraction: 0,
                barSweepPointsPerSecond: 10,
                panelSweepPointsPerSecond: 10,
                headPulseHertz: 0.5,
                lightHex: "#6E6E6E",
                darkHex: "#8A8A8A"
            )
        }
    }

    /// Poor and Offline are the only states the spec announces politely.
    public var announcesStateChangePolitely: Bool {
        self == .poor || self == .offline
    }

    public func accessibilityLabel(host: String, medianRTT: TimeInterval?) -> String {
        switch self {
        case .unknown:
            return "Network health: Unknown"
        case .offline where medianRTT == nil:
            return "Network health: Offline"
        default:
            let milliseconds = Int(((medianRTT ?? 0) * 1_000).rounded())
            return "Network health: \(spokenName), \(milliseconds) ms"
        }
    }
}

/// Drawing data for one state. Speeds are points per second on the badge and the panel.
public struct HealthPresentation: Equatable, Sendable {
    public var state: HealthState
    public var label: String
    public var glyphName: String
    public var beatShapeID: String
    public var beatsPerMinute: Double
    /// Fair stretches each beat by this factor. Other states use 1.
    public var beatWidthScale: Double
    /// Poor varies the gap between beats by this fraction of the interval.
    public var intervalJitterFraction: Double
    /// Poor varies beat height by this fraction.
    public var beatHeightJitterFraction: Double
    /// Badge trace, concept 3. Zero while idle.
    public var barSweepPointsPerSecond: Double
    /// Monitor trace inside the panel.
    public var panelSweepPointsPerSecond: Double
    /// Offline head dot. Zero for every other state.
    public var headPulseHertz: Double
    public var lightHex: String
    public var darkHex: String
}

/// One probe inside the rolling window. `rtt` is nil when the probe got no answer.
public struct HealthSample: Equatable, Sendable {
    public var timestamp: Date
    public var rtt: TimeInterval?
    public var lost: Bool

    public init(timestamp: Date, rtt: TimeInterval?, lost: Bool) {
        self.timestamp = timestamp
        self.rtt = rtt
        self.lost = lost
    }

    public var rttMilliseconds: Double? {
        rtt.map { $0 * 1_000 }
    }
}

/// Aggregates over the samples still inside the window. Memory only.
public struct HealthStats: Equatable, Sendable {
    public var medianRTT: TimeInterval?
    public var meanRTT: TimeInterval?
    public var jitter: TimeInterval?
    /// 0...100. Zero when the window is empty.
    public var lossPercent: Double
    public var sampleCount: Int
    public var lostCount: Int
    public var receivedCount: Int

    public init(
        medianRTT: TimeInterval?,
        meanRTT: TimeInterval?,
        jitter: TimeInterval?,
        lossPercent: Double,
        sampleCount: Int,
        lostCount: Int,
        receivedCount: Int
    ) {
        self.medianRTT = medianRTT
        self.meanRTT = meanRTT
        self.jitter = jitter
        self.lossPercent = lossPercent
        self.sampleCount = sampleCount
        self.lostCount = lostCount
        self.receivedCount = receivedCount
    }

    public static let empty = HealthStats(
        medianRTT: nil,
        meanRTT: nil,
        jitter: nil,
        lossPercent: 0,
        sampleCount: 0,
        lostCount: 0,
        receivedCount: 0
    )

    public var medianMilliseconds: Int? {
        medianRTT.map { Int(($0 * 1_000).rounded()) }
    }

    public var meanMilliseconds: Int? {
        meanRTT.map { Int(($0 * 1_000).rounded()) }
    }

    public var jitterMilliseconds: Int? {
        jitter.map { Int(($0 * 1_000).rounded()) }
    }

    static func compute(from samples: [HealthSample]) -> HealthStats {
        let ordered = samples.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return false
        }
        var lostCount = 0
        var rtts: [TimeInterval] = []
        rtts.reserveCapacity(ordered.count)
        for sample in ordered {
            if let rtt = sample.rtt, sample.lost == false, rtt >= 0 {
                rtts.append(rtt)
            } else {
                lostCount += 1
            }
        }
        let sampleCount = ordered.count
        let lossPercent = sampleCount == 0 ? 0 : Double(lostCount) / Double(sampleCount) * 100
        return HealthStats(
            medianRTT: median(of: rtts),
            meanRTT: rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count),
            jitter: successiveJitter(of: rtts),
            lossPercent: lossPercent,
            sampleCount: sampleCount,
            lostCount: lostCount,
            receivedCount: rtts.count
        )
    }

    private static func median(of values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Mean absolute difference of successive received RTTs, in time order.
    /// Lost probes are already omitted. Nil until two replies exist.
    private static func successiveJitter(of rtts: [TimeInterval]) -> TimeInterval? {
        guard rtts.count >= 2 else { return nil }
        var sum = 0.0
        for index in 1..<rtts.count {
            sum += abs(rtts[index] - rtts[index - 1])
        }
        return sum / Double(rtts.count - 1)
    }
}

/// Maps window stats to good / fair / poor / unknown. Offline is the state machine's job.
public enum HealthClassifier {
    public static func classify(_ stats: HealthStats) -> HealthState {
        guard stats.sampleCount > 0 else { return .unknown }
        // lost/total > 2/100, compared in integers so 1/50 stays exactly 2 percent.
        if stats.lostCount * 50 > stats.sampleCount {
            return .poor
        }
        if let jitter = stats.jitter, microseconds(jitter) > HealthLimits.jitterPoorMilliseconds * 1_000 {
            return .poor
        }
        guard let median = stats.medianRTT else {
            return .poor
        }
        let rtt = microseconds(median)
        if rtt > HealthLimits.fairUpperMilliseconds * 1_000 {
            return .poor
        }
        if rtt < HealthLimits.goodUpperMilliseconds * 1_000 {
            return .good
        }
        return .fair
    }

    /// Nearest microsecond, so 79.000 ms stays under 80 and 100.1 ms of jitter stays over 100.
    static func microseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1_000_000).rounded())
    }
}
