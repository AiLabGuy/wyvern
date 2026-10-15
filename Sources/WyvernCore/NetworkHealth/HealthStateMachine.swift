// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the badge and the monitor panel read after a sample or a clock tick.
public struct HealthReading: Equatable, Sendable {
    public var state: HealthState
    public var stats: HealthStats
    public var samples: [HealthSample]
    public var presentation: HealthPresentation

    public init(
        state: HealthState,
        stats: HealthStats,
        samples: [HealthSample],
        presentation: HealthPresentation
    ) {
        self.state = state
        self.stats = stats
        self.samples = samples
        self.presentation = presentation
    }
}

/// Pure classifier over a window. The caller injects time; this type does no I/O.
///
/// A new good / fair / poor value is published only after two consecutive
/// samples classify the same way. Offline is different: three seconds with no
/// successful reply publishes immediately, because that wait is the debounce.
public struct HealthStateMachine: Equatable {
    public private(set) var state: HealthState
    public let silenceInterval: TimeInterval
    public let samplesToCommit: Int

    private var window: HealthWindow
    private var pending: HealthState?
    private var pendingCount: Int
    private var lastSuccessAt: Date?
    private var startedAt: Date?
    private let clock: () -> Date

    public init(
        clock: @escaping () -> Date = Date.init,
        windowDuration: TimeInterval = HealthLimits.windowDuration,
        silenceInterval: TimeInterval = HealthLimits.offlineSilence,
        samplesToCommit: Int = HealthLimits.samplesToCommit
    ) {
        self.state = .unknown
        self.window = HealthWindow(duration: windowDuration)
        self.silenceInterval = silenceInterval
        self.samplesToCommit = samplesToCommit
        self.pending = nil
        self.pendingCount = 0
        self.lastSuccessAt = nil
        self.startedAt = nil
        self.clock = clock
    }

    public static func == (lhs: HealthStateMachine, rhs: HealthStateMachine) -> Bool {
        lhs.state == rhs.state
            && lhs.silenceInterval == rhs.silenceInterval
            && lhs.samplesToCommit == rhs.samplesToCommit
            && lhs.window == rhs.window
            && lhs.pending == rhs.pending
            && lhs.pendingCount == rhs.pendingCount
            && lhs.lastSuccessAt == rhs.lastSuccessAt
            && lhs.startedAt == rhs.startedAt
    }

    public mutating func reset() {
        let duration = window.duration
        state = .unknown
        window = HealthWindow(duration: duration)
        pending = nil
        pendingCount = 0
        lastSuccessAt = nil
        startedAt = nil
    }

    /// Restores a pane's committed state and samples. The next probe continues this history.
    public mutating func restore(state: HealthState, samples: [HealthSample], at time: Date) {
        window.restore(samples, now: time)
        self.state = state
        pending = state
        pendingCount = samplesToCommit
        lastSuccessAt = samples.last(where: { $0.lost == false && $0.rtt != nil })?.timestamp
        startedAt = samples.map(\.timestamp).min() ?? time
    }

    /// Marks the moment probing started, so silence can elapse before the first sample.
    public mutating func begin(at time: Date? = nil) {
        let time = time ?? clock()
        if startedAt == nil {
            startedAt = time
        }
    }

    @discardableResult
    public mutating func record(rtt: TimeInterval?, lost: Bool, at time: Date? = nil) -> HealthReading {
        let time = time ?? clock()
        begin(at: time)
        let answered = lost == false && rtt != nil && (rtt ?? 0) >= 0
        let sample = HealthSample(
            timestamp: time,
            rtt: answered ? rtt : nil,
            lost: !answered
        )
        window.add(sample, now: time)
        if answered {
            lastSuccessAt = time
        }
        return evaluate(at: time, sampleArrived: true)
    }

    /// Clock moved and no sample arrived. Expires the window and applies the silence rule.
    @discardableResult
    public mutating func advance(to time: Date? = nil) -> HealthReading {
        let time = time ?? clock()
        window.expire(now: time)
        return evaluate(at: time, sampleArrived: false)
    }

    /// The path has no route. Offline is immediate; the three-second wait does not apply.
    @discardableResult
    public mutating func noteNoRoute(at time: Date? = nil) -> HealthReading {
        let time = time ?? clock()
        begin(at: time)
        enterOffline()
        return reading(at: time)
    }

    public func reading(at time: Date? = nil) -> HealthReading {
        let time = time ?? clock()
        let stats = window.stats(at: time)
        return HealthReading(
            state: state,
            stats: stats,
            samples: window.samples(at: time),
            presentation: state.presentation
        )
    }

    private mutating func evaluate(at time: Date, sampleArrived: Bool) -> HealthReading {
        if isSilent(at: time) {
            enterOffline()
            return reading(at: time)
        }
        if sampleArrived {
            let candidate = HealthClassifier.classify(window.stats(at: time))
            applyHysteresis(candidate)
        }
        return reading(at: time)
    }

    private func isSilent(at time: Date) -> Bool {
        guard let startedAt else { return false }
        let anchor = lastSuccessAt ?? startedAt
        return time.timeIntervalSince(anchor) >= silenceInterval
    }

    private mutating func enterOffline() {
        guard state != .offline else { return }
        state = .offline
        pending = nil
        pendingCount = 0
    }

    private mutating func applyHysteresis(_ candidate: HealthState) {
        // An empty window is not evidence, so it must not wipe a state we already showed.
        if candidate == .unknown || candidate == state {
            pending = nil
            pendingCount = 0
            return
        }
        if pending == candidate {
            pendingCount += 1
        } else {
            pending = candidate
            pendingCount = 1
        }
        if pendingCount >= samplesToCommit {
            state = candidate
            pending = nil
            pendingCount = 0
        }
    }
}
