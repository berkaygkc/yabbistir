import CoreGraphics
import Testing
@testable import YabPlatform

@Suite struct PanelPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 680, height: 476)

    @Test func opensBelowCaret() {
        let placed = PanelPlacement.place(panelSize: size, caret: CGRect(x: 500, y: 600, width: 2, height: 17), visibleFrame: screen)
        #expect(placed.frame.maxY == 592)
        #expect(placed.frame.minX == 476)
        #expect(placed.frame.height == 476)
        #expect(placed.opensAbove == false)
    }

    @Test func flipsAboveWhenNoRoomBelow() {
        let placed = PanelPlacement.place(panelSize: size, caret: CGRect(x: 500, y: 300, width: 2, height: 17), visibleFrame: screen)
        #expect(placed.opensAbove)
        #expect(placed.frame.minY == 325)
        #expect(placed.frame.height == 476)
    }

    @Test func shrinksIntoLargerSide() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 700)
        let placed = PanelPlacement.place(panelSize: size, caret: CGRect(x: 500, y: 340, width: 2, height: 17), visibleFrame: short)
        #expect(placed.opensAbove)
        #expect(placed.frame.height == 323)
        #expect(placed.frame.minY == 365)
    }

    @Test(arguments: [
        (CGRect(x: 0, y: 0, width: 1440, height: 875), CGRect(x: 500, y: 600, width: 2, height: 17)),
        (CGRect(x: 0, y: 0, width: 1440, height: 875), CGRect(x: 500, y: 300, width: 2, height: 17)),
        (CGRect(x: 0, y: 0, width: 1440, height: 700), CGRect(x: 500, y: 340, width: 2, height: 17)),
    ])
    func neverCoversCaret(screen: CGRect, caret: CGRect) {
        let placed = PanelPlacement.place(panelSize: size, caret: caret, visibleFrame: screen)
        #expect(!placed.frame.intersects(caret))
    }

    @Test func clampsHorizontally() {
        let placed = PanelPlacement.place(panelSize: size, caret: CGRect(x: 1400, y: 600, width: 2, height: 17), visibleFrame: screen)
        #expect(placed.frame.maxX == 1428)
    }

    @Test func negativeOriginScreen() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let placed = PanelPlacement.place(panelSize: size, caret: CGRect(x: -300, y: 500, width: 2, height: 17), visibleFrame: left)
        #expect(left.insetBy(dx: 12, dy: 12).contains(placed.frame))
    }

    @Test func minimumHeightRespected() {
        // Caret positioned so both sides offer exactly 200 pt.
        let cramped = CGRect(x: 0, y: 0, width: 1440, height: 457)
        let placed = PanelPlacement.place(panelSize: size, caret: CGRect(x: 500, y: 220, width: 2, height: 17), visibleFrame: cramped)
        #expect(placed.frame.height == 260)
        #expect(cramped.insetBy(dx: 12, dy: 12).contains(placed.frame))
    }

    @Test func growingKeepsTheLeftEdgeWhenItFits() {
        let wide = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let r = PanelPlacement.resized(CGRect(x: 100, y: 300, width: 340, height: 476), toWidth: 680, visibleFrame: wide)
        #expect(r == CGRect(x: 100, y: 300, width: 680, height: 476))
    }

    @Test func growingShiftsLeftAtTheScreenEdge() {
        let wide = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let r = PanelPlacement.resized(CGRect(x: 1200, y: 300, width: 340, height: 476), toWidth: 680, visibleFrame: wide)
        #expect(r.maxX == wide.maxX - 12)
        #expect(r.minY == 300)
    }
}
