import Foundation

/// What a clipboard item is, as far as the UI and extensions are concerned.
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text, code, link, color, image, file
}

/// Where a clip came from: this Mac, or another device via Universal Clipboard.
public enum DeviceKind: String, Codable, Sendable {
    case local, remote
}

/// One pasteboard type and its raw bytes, stored with full fidelity.
public struct PasteboardRepresentation: Codable, Sendable, Hashable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public struct SourceApp: Codable, Sendable, Hashable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// A pasteboard snapshot as captured: one array of representations per pasteboard item.
public struct CapturedClip: Sendable {
    public var items: [[PasteboardRepresentation]]
    public var source: SourceApp?
    public var device: DeviceKind
    public var capturedAt: Date

    public init(items: [[PasteboardRepresentation]], source: SourceApp?, device: DeviceKind, capturedAt: Date) {
        self.items = items
        self.source = source
        self.device = device
        self.capturedAt = capturedAt
    }
}

public enum TypeIdentifiers {
    public static let plainText = "public.utf8-plain-text"
    public static let rtf = "public.rtf"
    public static let url = "public.url"
    public static let urlName = "public.url-name"
    public static let fileURL = "public.file-url"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let jpeg = "public.jpeg"
    public static let heic = "public.heic"
}
