import CoreGraphics
import Testing
@testable import YabPlatform

/// The job card hangs from the menu bar status item: its top 7 pt below the
/// icon, its right edge 10 pt past the icon's, kept 8 pt inside the screen.
@Suite struct JobCardPlacementTests {
    /// A 1512 × 982 screen with a 38 pt menu bar: the visible frame stops under it.
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let card = CGSize(width: 320, height: 72)

    func icon(x: CGFloat) -> CGRect { CGRect(x: x, y: 944, width: 30, height: 38) }

    @Test func hangsUnderTheIconPastItsRightEdge() {
        let placed = JobCardPlacement.place(cardSize: card, icon: icon(x: 1300), visibleFrame: visible)
        #expect(placed.frame.maxY == 937) // 944 − 7
        #expect(placed.frame.maxX == 1340) // 1330 + 10
        #expect(placed.frame.size == card)
    }

    /// An icon near the right edge: the card stops 8 pt short of it instead of running off.
    @Test func staysEightPointsInsideTheRightEdge() {
        let placed = JobCardPlacement.place(cardSize: card, icon: icon(x: 1478), visibleFrame: visible)
        #expect(placed.frame.maxX == 1504) // 1512 − 8
        #expect(placed.frame.maxY == 937) // 944 − 7
    }

    @Test func staysEightPointsInsideTheLeftEdge() {
        let placed = JobCardPlacement.place(cardSize: card, icon: icon(x: 40), visibleFrame: visible)
        #expect(placed.frame.minX == 8)
    }

    /// On a second screen to the right, the margins are that screen's.
    @Test func usesTheIconsOwnScreen() {
        let second = CGRect(x: 1512, y: -200, width: 1920, height: 1050)
        let onSecond = CGRect(x: 3400, y: 850, width: 30, height: 24)
        let placed = JobCardPlacement.place(cardSize: card, icon: onSecond, visibleFrame: second)
        #expect(placed.frame.maxX == 3424) // 3432 − 8
        #expect(placed.frame.maxY == 843) // 850 − 7
    }

    /// The card grows from under the icon: the icon's centre, as a share of the card's width.
    @Test func growsFromUnderTheIcon() {
        let placed = JobCardPlacement.place(cardSize: card, icon: icon(x: 1300), visibleFrame: visible)
        #expect(placed.growAnchorX == (1315 - placed.frame.minX) / 320)
        let clamped = JobCardPlacement.place(cardSize: card, icon: icon(x: 1490), visibleFrame: visible)
        #expect(clamped.growAnchorX == 1)
    }
}
