import Foundation
import YabCore

/// ⌘⇧C's ⌘C copied nothing, yet the app in front may have copied the selection on its own a moment before: a
/// full-screen command-line program that selects with the mouse itself copies as the mouse lets go, and leaves the
/// terminal no selection for ⌘C to find. That copy is what the person meant, if it is that recent and from that app.
public enum RecentCopy {
    /// How long before the press a copy still counts. Short, so an older copy never opens the Sıra by surprise.
    public static let window: TimeInterval = 3

    /// The item to put in the Sıra, or nil. A copy that lands just after the press counts too.
    public static func meant(_ last: ClipItem?, frontApp: String?, pressedAt: Date) -> Int64? {
        guard let last, let id = last.id, last.device == .local, let frontApp, last.sourceBundleID == frontApp,
              pressedAt.timeIntervalSince(last.lastCopiedAt) <= window else { return nil }
        return id
    }
}
