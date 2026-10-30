import AppKit
import YabCore

/// Puts a capture rule's clean copy back on the clipboard, only over the copy it was made from.
@MainActor
public protocol CleanWriting: AnyObject {
    /// Writes `items` when the clipboard still holds the copy read at `changeCount`, and tells the monitor to
    /// let that write pass. False when anything changed the clipboard since: a newer copy is never overwritten.
    func writeIfUnchanged(_ items: [[PasteboardRepresentation]], expected changeCount: Int) -> Bool
}

/// `CleanWriting` on a real pasteboard. `didWrite` gets the new change count (`PasteboardMonitor.ignore`).
@MainActor
public final class SystemCleanWriter: CleanWriting {
    private let pasteboard: NSPasteboard
    private let didWrite: (Int) -> Void

    public init(pasteboard: NSPasteboard = .general, didWrite: @escaping (Int) -> Void) {
        self.pasteboard = pasteboard
        self.didWrite = didWrite
    }

    public func writeIfUnchanged(_ items: [[PasteboardRepresentation]], expected changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        didWrite(SystemPasteboardWriter(pasteboard: pasteboard).write(items, plainTextOnly: false))
        return true
    }
}
