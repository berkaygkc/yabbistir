import CoreGraphics

/// Where a notice that belongs to no open panel goes (an extension's `yab.notify`, a language pack's download): it
/// hangs from the menu bar status item as the job card does (`JobCardPlacement`), and under the card while that
/// shows, their right edges together, so neither covers the other. Kept 8 pt inside the screen. Cocoa global
/// coordinates, y up.
public enum NoticePlacement {
    /// `icon`: the status item's button on screen; `visibleFrame`: its screen's; `jobCard`: the card while it shows.
    public static func underStatusItem(size: CGSize, icon: CGRect, visibleFrame: CGRect, jobCard: CGRect?) -> CGRect {
        guard let card = jobCard else { return JobCardPlacement.place(cardSize: size, icon: icon, visibleFrame: visibleFrame).frame }
        let margin = JobCardPlacement.margin
        let x = max(visibleFrame.minX + margin, min(card.maxX - size.width, visibleFrame.maxX - margin - size.width))
        let y = max(visibleFrame.minY + margin, card.minY - JobCardPlacement.gap - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
