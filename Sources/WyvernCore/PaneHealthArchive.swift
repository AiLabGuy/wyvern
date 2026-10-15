// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How often a visible pane is probed. The focused pane keeps the existing one-second interval.
/// Unfocused visible panes are specified at 6 seconds. The live prober is still one host at a time,
/// so the 6 second interval is recorded here for that prober and is not a second ICMP loop.
public enum PaneProbeCadence {
    public static let focused: TimeInterval = HealthLimits.probeInterval
    public static let visibleUnfocused: TimeInterval = 6
}

/// Sample history for each pane, keyed by tab id. Switching panes reads the stored record
/// instead of starting again at unknown. Records leave when the tab leaves the window.
public struct PaneHealthArchive<Record: Equatable & Sendable>: Equatable, Sendable {
    private var records: [UUID: Record] = [:]

    public init() {}

    public var count: Int { records.count }

    public mutating func remember(_ record: Record, for tabID: UUID) {
        records[tabID] = record
    }

    public func record(for tabID: UUID) -> Record? {
        records[tabID]
    }

    public mutating func prune(keeping ids: Set<UUID>) {
        records = records.filter { ids.contains($0.key) }
    }
}
