import CoreGraphics

public enum PreviewSide: Equatable, Sendable {
    case left, right, above, below, over
}

/// Where the preview goes (Cocoa coordinates). Beside the panel on the side away
/// from the focused column, else above or below it, and over the panel only as a last resort.
public enum PreviewPlacement {
    public static let width: CGFloat = 400
    public static let gap: CGFloat = 12
    public static let margin: CGFloat = 12

    /// `columnIndex` counts the columns on screen; `row` is the selected row, if any; `caret` is
    /// the text caret the panel was opened for.
    public static func place(panel: CGRect, column: CGRect, row: CGRect?, caret: CGRect? = nil, columnIndex: Int, visibleColumns: Int,
                             size: CGSize, visibleFrame: CGRect) -> (side: PreviewSide, frame: CGRect) {
        // Caret Is Sacred: above and below are measured beyond the caret's line, not just the panel.
        let guarded = caret.map { panel.union($0) } ?? panel
        let room: [PreviewSide: CGFloat] = [
            .left: panel.minX - gap - (visibleFrame.minX + margin),
            .right: (visibleFrame.maxX - margin) - (panel.maxX + gap),
            .above: (visibleFrame.maxY - margin) - (guarded.maxY + gap),
            .below: (guarded.minY - gap) - (visibleFrame.minY + margin),
        ]
        let order: [PreviewSide] = if visibleColumns <= 1 { [.right, .left, .above, .below] }
            else if columnIndex == 0 { [.left, .above, .below, .right] }
            else if columnIndex == visibleColumns - 1 { [.right, .above, .below, .left] }
            else { [.above, .below, .left, .right] }
        let side = order.first { side in
            (side == .left || side == .right) ? room[side, default: 0] >= width : room[side, default: 0] >= 200
        } ?? .over

        switch side {
        case .left, .right:
            let height = min(size.height, visibleFrame.height - 2 * margin)
            let x = side == .left ? panel.minX - gap - width : panel.maxX + gap
            // Top-aligned 8 pt above the selected row, kept on screen.
            let top = (row?.maxY ?? panel.maxY) + 8
            let y = max(visibleFrame.minY + margin, min(top - height, visibleFrame.maxY - margin - height))
            return (side, CGRect(x: x, y: y, width: width, height: height))
        case .above, .below:
            let height = min(size.height, room[side, default: 0], 480)
            let x = max(visibleFrame.minX + margin, min(column.midX - width / 2, visibleFrame.maxX - margin - width))
            let y = side == .above ? guarded.maxY + gap : guarded.minY - gap - height
            return (side, CGRect(x: x, y: y, width: width, height: height))
        case .over:
            let height = min(size.height, panel.height - 16)
            let x = columnIndex == 0 ? panel.maxX - width - 8 : panel.minX + 8
            return (side, CGRect(x: x, y: panel.maxY - 8 - height, width: width, height: height))
        }
    }
}
