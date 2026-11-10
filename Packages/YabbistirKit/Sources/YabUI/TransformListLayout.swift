import CoreGraphics

/// How tall the ⇧ panel's list stands. While its rows fit under the panel's other parts inside the screen, the list is
/// as tall as they are and nothing scrolls: the panel looks as it always has. Once they don't, the list keeps the height
/// that is left and scrolls, so the panel never runs past the screen's visible frame.
public enum TransformListLayout {
    public struct Fit: Equatable, Sendable {
        /// The list's height on screen.
        public let height: CGFloat
        /// Whether its rows are taller than `height`, so it scrolls.
        public let scrolls: Bool

        public init(height: CGFloat, scrolls: Bool) {
            self.height = height
            self.scrolls = scrolls
        }
    }

    /// A row: a menu row.
    public static let rowHeight: CGFloat = 32
    /// A section's header ("Base64", "Finder’a"): its 14 pt line with 9 pt above and 4 pt below.
    public static let sectionHeight: CGFloat = 27

    /// The list's own height: its rows, and a header for each of its sections.
    public static func contentHeight(rows: Int, rowHeight: CGFloat = rowHeight, sections: Int = 0,
                                     sectionHeight: CGFloat = sectionHeight) -> CGFloat {
        CGFloat(max(0, rows)) * rowHeight + CGFloat(max(0, sections)) * sectionHeight
    }

    /// `available`: the height the panel's other parts leave for the list inside the screen's margins. A list that
    /// scrolls takes all of it, in whole points, and keeps at least one row however short the screen.
    public static func fit(rows: Int, rowHeight: CGFloat = rowHeight, sections: Int = 0, sectionHeight: CGFloat = sectionHeight,
                           available: CGFloat) -> Fit {
        let content = contentHeight(rows: rows, rowHeight: rowHeight, sections: sections, sectionHeight: sectionHeight)
        guard content > available else { return Fit(height: content, scrolls: false) }
        return Fit(height: max(available.rounded(.down), min(rowHeight, content)), scrolls: true)
    }
}
