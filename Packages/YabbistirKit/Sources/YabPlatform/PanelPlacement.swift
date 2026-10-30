import CoreGraphics

public struct PlacedPanel: Equatable, Sendable {
    public var frame: CGRect
    public var opensAbove: Bool
}

/// Positions the panel relative to the text caret (Cocoa global coordinates, y up).
/// Rule: below the caret; above if it only fits there; otherwise the roomier side,
/// shrunk to fit but never below `minHeight`. The panel never covers the caret
/// unless the screen is too short for `minHeight` on either side.
public enum PanelPlacement {
    public static func place(panelSize: CGSize, caret: CGRect, visibleFrame: CGRect,
                             gap: CGFloat = 8, leadingOffset: CGFloat = 24, margin: CGFloat = 12,
                             minHeight: CGFloat = 260) -> PlacedPanel {
        let roomBelow = caret.minY - gap - (visibleFrame.minY + margin)
        let roomAbove = (visibleFrame.maxY - margin) - (caret.maxY + gap)

        let height: CGFloat
        let opensAbove: Bool
        if panelSize.height <= roomBelow {
            (height, opensAbove) = (panelSize.height, false)
        } else if panelSize.height <= roomAbove {
            (height, opensAbove) = (panelSize.height, true)
        } else if roomAbove > roomBelow {
            (height, opensAbove) = (max(minHeight, roomAbove), true)
        } else {
            (height, opensAbove) = (max(minHeight, roomBelow), false)
        }

        var minY = opensAbove ? caret.maxY + gap : caret.minY - gap - height
        minY = min(max(minY, visibleFrame.minY + margin), visibleFrame.maxY - margin - height)

        let preferredX = caret.minX - leadingOffset
        let minX = max(visibleFrame.minX + margin, min(preferredX, visibleFrame.maxX - margin - panelSize.width))

        return PlacedPanel(frame: CGRect(x: minX, y: minY, width: panelSize.width, height: height), opensAbove: opensAbove)
    }

    /// The panel widened or narrowed to `width` (columns opened or closed): the left edge stays
    /// unless the panel would leave the screen, and the vertical position never changes, so the
    /// caret stays uncovered.
    public static func resized(_ frame: CGRect, toWidth width: CGFloat, visibleFrame: CGRect, margin: CGFloat = 12) -> CGRect {
        let x = max(visibleFrame.minX + margin, min(frame.minX, visibleFrame.maxX - margin - width))
        return CGRect(x: x, y: frame.minY, width: width, height: frame.height)
    }
}
