import AppKit
import YabCore

public protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    func readItems() -> [[PasteboardRepresentation]]
}

/// Reads every type of every item on the general pasteboard.
public final class SystemPasteboardReader: PasteboardReading {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func readItems() -> [[PasteboardRepresentation]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { PasteboardRepresentation(type: type.rawValue, data: $0) }
            }
        }
    }
}

public protocol FrontmostAppProviding: AnyObject {
    func frontmostApplication() -> SourceApp?
}

public final class WorkspaceAppProvider: FrontmostAppProviding {
    public init() {}

    public func frontmostApplication() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else { return nil }
        return SourceApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }
}
