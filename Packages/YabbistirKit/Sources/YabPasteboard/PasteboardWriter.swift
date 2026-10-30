import AppKit
import YabCore

public protocol PasteboardWriting: AnyObject {
    /// Replaces the pasteboard contents and returns the new change count.
    @discardableResult
    func write(_ items: [[PasteboardRepresentation]], plainTextOnly: Bool) -> Int
}

public final class SystemPasteboardWriter: PasteboardWriting {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    public func write(_ items: [[PasteboardRepresentation]], plainTextOnly: Bool) -> Int {
        pasteboard.clearContents()
        // A plain paste of an item without text (an image, files) pastes the item itself.
        if plainTextOnly, let text = Self.plainText(items) {
            pasteboard.setString(text, forType: .string)
            return pasteboard.changeCount
        }
        let objects = items.map { reps in
            let item = NSPasteboardItem()
            for rep in reps { item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
            return item
        }
        pasteboard.writeObjects(objects)
        return pasteboard.changeCount
    }

    static func plainText(_ items: [[PasteboardRepresentation]]) -> String? {
        guard let first = items.first else { return nil }
        if let plain = first.first(where: { $0.type == TypeIdentifiers.plainText }) {
            return String(decoding: plain.data, as: UTF8.self)
        }
        if let rtf = first.first(where: { $0.type == TypeIdentifiers.rtf }) {
            return NSAttributedString(rtf: rtf.data, documentAttributes: nil)?.string
        }
        return nil
    }
}
