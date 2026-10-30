import CoreGraphics

public struct PlacedJobCard: Equatable, Sendable {
    public var frame: CGRect
    /// Where the card grows from on its top edge: under the icon's centre, as a share of its width (0…1).
    public var growAnchorX: CGFloat
}

/// Where the job card hangs: from the menu bar status item, like the icon's
/// own menu. Its top sits 7 pt below the icon and its right edge 10 pt past the icon's, kept 8 pt
/// inside the screen the icon is on. Cocoa global coordinates, y up.
public enum JobCardPlacement {
    public static let gap: CGFloat = 7
    public static let overhang: CGFloat = 10
    public static let margin: CGFloat = 8

    /// `icon`: the status item's button on screen; `visibleFrame`: its screen's.
    public static func place(cardSize: CGSize, icon: CGRect, visibleFrame: CGRect) -> PlacedJobCard {
        let preferredX = icon.maxX + overhang - cardSize.width
        let x = max(visibleFrame.minX + margin, min(preferredX, visibleFrame.maxX - margin - cardSize.width))
        let frame = CGRect(x: x, y: icon.minY - gap - cardSize.height, width: cardSize.width, height: cardSize.height)
        let anchor = cardSize.width > 0 ? (icon.midX - frame.minX) / cardSize.width : 1
        return PlacedJobCard(frame: frame, growAnchorX: min(1, max(0, anchor)))
    }
}
