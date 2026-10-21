// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics

/// Geometry for one Settings → Appearance → Icons tile: the icon square on top, the label below.
///
/// Coordinates are top-down (the tile view is flipped). The tile asks for `size` as its intrinsic
/// content size, so a stack row cannot shrink it to a text button's height. Before this, the tile
/// was as tall as its title (about 20 pt) and the icon was drawn above its top edge, so only a
/// sliver showed and the selection ring was cut off.
public enum IconTileLayout {
    public static let maxSide: CGFloat = 64
    public static let minSide: CGFloat = 32
    public static let topInset: CGFloat = 4
    public static let labelGap: CGFloat = 6
    public static let bottomInset: CGFloat = 4
    public static let horizontalInset: CGFloat = 4
    public static let preferredWidth: CGFloat = maxSide + 2 * horizontalInset

    public static func height(labelHeight: CGFloat) -> CGFloat {
        topInset + maxSide + labelGap + labelHeight + bottomInset
    }

    public static func size(labelHeight: CGFloat) -> CGSize {
        CGSize(width: preferredWidth, height: height(labelHeight: labelHeight))
    }

    /// Icon side for a tile: as large as fits, up to `maxSide`.
    public static func side(in bounds: CGSize, labelHeight: CGFloat) -> CGFloat {
        let byWidth = bounds.width - 2 * horizontalInset
        let byHeight = bounds.height - topInset - labelGap - labelHeight - bottomInset
        return max(0, min(maxSide, byWidth, byHeight))
    }

    /// The icon square and the label rect, top-down, centered horizontally.
    public static func frames(in bounds: CGSize, labelSize: CGSize) -> (thumb: CGRect, label: CGRect) {
        let side = side(in: bounds, labelHeight: labelSize.height)
        let thumb = CGRect(x: (bounds.width - side) / 2, y: topInset, width: side, height: side)
        let label = CGRect(
            x: (bounds.width - labelSize.width) / 2,
            y: thumb.maxY + labelGap,
            width: labelSize.width,
            height: labelSize.height
        )
        return (thumb, label)
    }
}
