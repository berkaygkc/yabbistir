import CoreGraphics
import Testing
@testable import YabPlatform

/// Screen 1728×1080; the focused column is `focus` × 340 from the panel's left, the selected row
/// 100 pt below the panel's top, the preview 400×300.
private func place(panel: CGRect, columns: Int, focus: Int) -> (side: PreviewSide, frame: CGRect) {
    let column = CGRect(x: panel.minX + CGFloat(focus) * 340, y: panel.minY, width: 340, height: panel.height)
    let row = CGRect(x: column.minX + 8, y: panel.maxY - 140, width: 324, height: 40)
    return PreviewPlacement.place(panel: panel, column: column, row: row, columnIndex: focus, visibleColumns: columns,
                                  size: CGSize(width: 400, height: 300), visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080))
}

@Suite struct PreviewPlacementTests {
    @Test func singleColumnPrefersRight() {
        let p = place(panel: CGRect(x: 600, y: 300, width: 340, height: 476), columns: 1, focus: 0)
        #expect(p.side == .right)
        #expect(p.frame.minX == CGFloat(600 + 340 + 12))
    }
    @Test func singleColumnAtTheRightEdgeGoesLeft() {
        #expect(place(panel: CGRect(x: 1300, y: 300, width: 340, height: 476), columns: 1, focus: 0).side == .left)
    }
    @Test func firstColumnGoesLeftThenAbove() {
        #expect(place(panel: CGRect(x: 600, y: 300, width: 1020, height: 476), columns: 3, focus: 0).side == .left)
        #expect(place(panel: CGRect(x: 100, y: 300, width: 1020, height: 476), columns: 3, focus: 0).side == .above)
    }
    @Test func middleColumnGoesAboveCentred() {
        let p = place(panel: CGRect(x: 300, y: 100, width: 1020, height: 476), columns: 3, focus: 1)
        #expect(p.side == .above)
        #expect(p.frame.midX == CGFloat(300 + 340 + 170))
    }
    @Test func noRoomAnywhereOverlapsOppositeTheFocus() {
        let p = PreviewPlacement.place(panel: CGRect(x: 12, y: 12, width: 1704, height: 1056), column: CGRect(x: 12, y: 12, width: 340, height: 1056),
                                       row: nil, columnIndex: 0, visibleColumns: 5, size: CGSize(width: 400, height: 300),
                                       visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080))
        #expect(p.side == .over)
        #expect(p.frame.maxX <= 12 + 1704 - 8)
    }

    /// Caret Is Sacred: the panel opened below the caret, so "above" starts above the caret line.
    @Test func abovePlacementNeverCoversTheCaret() {
        let panel = CGRect(x: 300, y: 100, width: 1020, height: 476)
        let caret = CGRect(x: 330, y: panel.maxY + 8, width: 1, height: 18)
        let column = CGRect(x: panel.minX + 340, y: panel.minY, width: 340, height: panel.height)
        let p = PreviewPlacement.place(panel: panel, column: column, row: nil, caret: caret, columnIndex: 1, visibleColumns: 3,
                                       size: CGSize(width: 400, height: 300), visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080))
        #expect(p.side == .above)
        #expect(p.frame.minY >= caret.maxY + 12)
    }

    @Test func noRoomAboveTheCaretGoesBelow() {
        let panel = CGRect(x: 300, y: 400, width: 1020, height: 476)
        let caret = CGRect(x: 330, y: panel.maxY + 8, width: 1, height: 18)
        let column = CGRect(x: panel.minX + 340, y: panel.minY, width: 340, height: panel.height)
        let p = PreviewPlacement.place(panel: panel, column: column, row: nil, caret: caret, columnIndex: 1, visibleColumns: 3,
                                       size: CGSize(width: 400, height: 300), visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080))
        #expect(p.side == .below)
    }
}
