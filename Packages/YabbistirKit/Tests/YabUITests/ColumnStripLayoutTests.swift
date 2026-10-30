import Testing
@testable import YabUI

/// Many columns on a small screen.
@Suite struct ColumnStripLayoutTests {
    @Test func sevenColumnsOnALaptopShowThreeAndNeverShrink() {
        #expect(ColumnStripLayout.visibleCount(total: 7, available: 1440 - 24) == 3)
        #expect(ColumnStripLayout.panelWidth(total: 7, available: 1416) == 3 * ColumnStripLayout.columnWidth)
    }

    @Test func focusBeyondTheRightEdgeScrollsJustEnough() {
        #expect(ColumnStripLayout.firstVisible(focus: 5, current: 0, visibleCount: 4, total: 7) == 2)
        #expect(ColumnStripLayout.firstVisible(focus: 1, current: 2, visibleCount: 4, total: 7) == 1)
        #expect(ColumnStripLayout.firstVisible(focus: 3, current: 2, visibleCount: 4, total: 7) == 2)
    }

    @Test func narrowScreenStillShowsOneWholeColumn() {
        #expect(ColumnStripLayout.visibleCount(total: 3, available: 300) == 1)
    }
}
