// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where a pointer sits inside a tile during a tab drag.
///
/// Edge bands match the existing 25% split-drop. The remaining interior is the
/// swap zone: the middle 50% of the tile on both axes, plus the top band when
/// the top edge is not a drop target (only DevTools uses the top edge).
public enum TileDropZone: Equatable, Sendable {
    case edge(TileEdge)
    case center
}

/// Pure hit-test for tile drag. Coordinates are a unit square, origin at the
/// bottom-left, matching AppKit.
public enum TileDropClassifier {
    /// Fraction of the tile treated as an edge. Left, right, and bottom (and
    /// top when allowed) still split or move, same as before this classifier.
    public static let edgeFraction: Double = 0.25

    /// The inner span that is always a swap, `1 - 2 * edgeFraction`.
    public static let centerFraction: Double = 1 - 2 * edgeFraction

    /// Classifies `x` and `y` in 0...1. Left and right win over up and down,
    /// matching the live drop hit-test. Non-finite values yield nil.
    public static func zone(x: Double, y: Double, allowTop: Bool) -> TileDropZone? {
        guard x.isFinite, y.isFinite else { return nil }
        if x <= edgeFraction { return .edge(.left) }
        if x >= 1 - edgeFraction { return .edge(.right) }
        if allowTop, y >= 1 - edgeFraction { return .edge(.up) }
        if y <= edgeFraction { return .edge(.down) }
        return .center
    }
}
