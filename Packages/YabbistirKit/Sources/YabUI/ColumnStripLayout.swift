import CoreGraphics

/// Horizontal layout of the panel's columns. Columns are always one width; when they do not all fit
/// on screen the strip shows whole columns and scrolls in column steps to keep focus visible.
public enum ColumnStripLayout {
    public static let columnWidth: CGFloat = Tokens.Metrics.columnWidth
    public static let screenMargin: CGFloat = 12

    public static func visibleCount(total: Int, available: CGFloat) -> Int {
        let fitting = available.isFinite ? Int((available / columnWidth).rounded(.down)) : total
        return max(1, min(total, fitting))
    }

    public static func panelWidth(total: Int, available: CGFloat) -> CGFloat {
        CGFloat(visibleCount(total: total, available: available)) * columnWidth
    }

    /// The smallest scroll from `current` that brings `focus` on screen.
    public static func firstVisible(focus: Int, current: Int, visibleCount: Int, total: Int) -> Int {
        let last = max(0, total - visibleCount)
        var first = min(max(0, current), last)
        if focus < first { first = focus } else if focus >= first + visibleCount { first = focus - visibleCount + 1 }
        return min(max(0, first), last)
    }
}
