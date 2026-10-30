import CoreGraphics
import Testing
@testable import YabPlatform

/// A notice that belongs to no open panel hangs from the menu bar status item, as the job card does; with the card
/// showing, it hangs under the card, so neither covers the other.
@Suite struct NoticePlacementTests {
    /// A 1512 × 982 screen with a 38 pt menu bar: the visible frame stops under it.
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let notice = CGSize(width: 300, height: 56)
    let icon = CGRect(x: 1300, y: 944, width: 30, height: 38)

    @Test func hangsFromTheStatusItemLikeTheJobCard() {
        let frame = NoticePlacement.underStatusItem(size: notice, icon: icon, visibleFrame: visible, jobCard: nil)
        #expect(frame == JobCardPlacement.place(cardSize: notice, icon: icon, visibleFrame: visible).frame)
        #expect(frame.maxY == 937) // 944 − 7
        #expect(frame.maxX == 1340) // 1330 + 10
    }

    /// Under the card, 7 pt below it, their right edges together.
    @Test func hangsUnderAShowingJobCard() {
        let card = JobCardPlacement.place(cardSize: CGSize(width: 320, height: 72), icon: icon, visibleFrame: visible).frame
        let frame = NoticePlacement.underStatusItem(size: notice, icon: icon, visibleFrame: visible, jobCard: card)
        #expect(frame.maxY == card.minY - 7)
        #expect(frame.maxX == card.maxX)
        #expect(frame.size == notice)
        #expect(!frame.intersects(card))
    }

    /// A notice wider than a card at the screen's left edge stays 8 pt inside it; a card that reaches the bottom leaves
    /// the notice 8 pt above the screen's edge rather than off it.
    @Test func staysOnScreen() {
        let wide = CGSize(width: 420, height: 56)
        let left = CGRect(x: 8, y: 865, width: 320, height: 72)
        #expect(NoticePlacement.underStatusItem(size: wide, icon: icon, visibleFrame: visible, jobCard: left).minX == 8)
        let tall = CGRect(x: 1180, y: 20, width: 324, height: 917)
        #expect(NoticePlacement.underStatusItem(size: notice, icon: icon, visibleFrame: visible, jobCard: tall).minY == 8)
    }
}
