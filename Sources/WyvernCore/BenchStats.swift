// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Summary of successful samples. Failed runs are counted in `errors` and excluded from the percentiles.
public struct BenchSummary: Equatable, Sendable {
    public var n: Int
    public var errors: Int
    public var median: Double?
    public var p90: Double?
    public var min: Double?
    public var max: Double?

    public init(n: Int, errors: Int, median: Double?, p90: Double?, min: Double?, max: Double?) {
        self.n = n
        self.errors = errors
        self.median = median
        self.p90 = p90
        self.min = min
        self.max = max
    }
}

public enum BenchStats {
    /// `values` are successful samples only. `errors` is the count of missed marks or timeouts.
    public static func summarize(values: [Double], errors: Int) -> BenchSummary {
        let sorted = values.sorted()
        guard !sorted.isEmpty else {
            return BenchSummary(n: 0, errors: errors, median: nil, p90: nil, min: nil, max: nil)
        }
        return BenchSummary(
            n: sorted.count,
            errors: errors,
            median: percentile(sorted, p: 50),
            p90: percentile(sorted, p: 90),
            min: sorted.first,
            max: sorted.last
        )
    }

    /// Linear interpolation on the sorted samples. `p` is 0...100.
    /// Even-n median is the mean of the two central values (p=50).
    public static func percentile(_ sorted: [Double], p: Double) -> Double {
        precondition(!sorted.isEmpty)
        if sorted.count == 1 {
            return sorted[0]
        }
        let clamped = min(100, max(0, p))
        let index = (clamped / 100.0) * Double(sorted.count - 1)
        let low = Int(index.rounded(.down))
        let high = Int(index.rounded(.up))
        if low == high {
            return sorted[low]
        }
        let weight = index - Double(low)
        return sorted[low] * (1 - weight) + sorted[high] * weight
    }
}
