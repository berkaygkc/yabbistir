import Foundation
import UniformTypeIdentifiers

/// A clipboard item as extensions see it. Concealed copies never become one.
public struct ExtensionItem: Codable, Equatable, Sendable {
    public struct ColorPayload: Codable, Equatable, Sendable {
        public var hex: String
        public var r: Int, g: Int, b: Int
        public var a: Double
        public init(hex: String, r: Int, g: Int, b: Int, a: Double) { (self.hex, self.r, self.g, self.b, self.a) = (hex, r, g, b, a) }
    }

    public struct FilePayload: Codable, Equatable, Sendable {
        public var path: String, name: String, size: Int, uti: String
        public init(path: String, name: String, size: Int, uti: String) { (self.path, self.name, self.size, self.uti) = (path, name, size, uti) }
    }

    public struct RichTextPayload: Codable, Equatable, Sendable {
        public var html: String?
        public init(html: String?) { self.html = html }
    }

    /// PNG data; the runtime turns it into an image handle.
    public struct ImagePayload: Codable, Equatable, Sendable {
        public var data: Data, width: Int, height: Int
        public init(data: Data, width: Int, height: Int) { (self.data, self.width, self.height) = (data, width, height) }
    }

    public struct SourcePayload: Codable, Equatable, Sendable {
        public var name: String?, bundleID: String?, device: String
        public init(name: String?, bundleID: String?, device: String) { (self.name, self.bundleID, self.device) = (name, bundleID, device) }
    }

    public var id: Int64
    public var kind: String
    public var text: String?
    public var url: String?
    public var color: ColorPayload?
    public var files: [FilePayload]?
    public var richText: RichTextPayload?
    public var image: ImagePayload?
    /// "extension.id:tag".
    public var tags: [String]
    public var source: SourcePayload?
    public var copiedAt: Date
    /// Set when `yab.history` cut the item's text or HTML to its byte limit; left out otherwise.
    public var truncated: Bool?

    public init(id: Int64, kind: String, text: String? = nil, url: String? = nil, color: ColorPayload? = nil, files: [FilePayload]? = nil,
                richText: RichTextPayload? = nil, image: ImagePayload? = nil, tags: [String] = [], source: SourcePayload? = nil,
                copiedAt: Date) {
        (self.id, self.kind, self.text, self.url, self.color, self.files) = (id, kind, text, url, color, files)
        (self.richText, self.image, self.tags, self.source, self.copiedAt) = (richText, image, tags, source, copiedAt)
    }

    /// One picture copied as a file (a PNG from Finder): actions that take images take it too,
    /// and get its pixels as `image`; its kind stays "file".
    public var isImageFile: Bool {
        guard kind == "file", let files, files.count == 1 else { return false }
        return UTType(files[0].uti)?.conforms(to: .image) == true
    }
}

/// What a call knows besides the item.
public struct ExtensionContext: Codable, Equatable, Sendable {
    public enum Trigger: String, Codable, Sendable { case search, shiftPanel, commandK, detect, preview, capture }

    public var language: String
    public var preferences: [String: JSONValue]
    public var trigger: Trigger
    public var variant: String?
    /// The app the result will be pasted into, when known.
    public var target: TargetInfo?
    /// Folders the person chose in Settings (never a manifest default): `yab.files.read` and `exists` may read inside
    /// them. Not part of `ctx`; the host keeps it for the call.
    public var readableFolders: [String]

    public init(language: String, preferences: [String: JSONValue] = [:], trigger: Trigger, variant: String? = nil, target: TargetInfo? = nil,
                readableFolders: [String] = []) {
        (self.language, self.preferences, self.trigger, self.variant, self.target) = (language, preferences, trigger, variant, target)
        self.readableFolders = readableFolders
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(language: try c.decode(String.self, forKey: .language),
                  preferences: try c.decode([String: JSONValue].self, forKey: .preferences),
                  trigger: try c.decode(Trigger.self, forKey: .trigger), variant: try c.decodeIfPresent(String.self, forKey: .variant),
                  target: try c.decodeIfPresent(TargetInfo.self, forKey: .target),
                  readableFolders: try c.decodeIfPresent([String].self, forKey: .readableFolders) ?? [])
    }
}
