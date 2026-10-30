import AppKit
import ImageIO

public struct Classification: Equatable, Sendable {
    public var kind: ItemKind
    public var previewText: String
    public var searchText: String

    public init(kind: ItemKind, previewText: String, searchText: String) {
        self.kind = kind
        self.previewText = previewText
        self.searchText = searchText
    }
}

/// Decides what a captured pasteboard snapshot is and derives its preview and search text.
/// Returns nil when nothing is worth keeping (blank text, private-only types).
public enum ItemClassifier {
    public static let previewLimit = 500
    public static let searchLimit = 20_000

    static let imageTypes: [(type: String, label: String)] = [
        (TypeIdentifiers.png, "PNG"), (TypeIdentifiers.jpeg, "JPEG"),
        (TypeIdentifiers.heic, "HEIC"), (TypeIdentifiers.tiff, "TIFF"),
    ]

    static let codeLeadWords: Set<String> = [
        "select", "update", "insert", "delete", "create", "alter", "drop", "with",
        "git", "docker", "swift", "xcrun", "npm", "yarn", "pnpm", "cd", "ls", "curl",
        "ssh", "brew", "kubectl", "make",
    ]
    static let codeMarkers = ["{", "}", "();", "=>", "->", "</", "/>", "::", "$("]

    public static func classify(_ items: [[PasteboardRepresentation]]) -> Classification? {
        guard let first = items.first, !first.isEmpty else { return nil }
        func data(_ type: String) -> Data? { first.first { $0.type == type }?.data }

        let fileURLs = items.compactMap { item in
            item.first { $0.type == TypeIdentifiers.fileURL }
                .flatMap { URL(string: String(decoding: $0.data, as: UTF8.self)) }
        }
        if !fileURLs.isEmpty {
            let names = fileURLs.map(\.lastPathComponent).joined(separator: ", ")
            return make(.file, preview: names, search: names)
        }

        let text = plainText(in: first)
        // Office and iWork attach a picture of copied text, and the text is what the user copied.
        // A lone URL next to an image is that image's address (a browser's "Copy Image").
        if text.map({ string in !string.contains { !$0.isWhitespace } || isWebURL(string) }) ?? true {
            for image in imageTypes {
                guard let bytes = data(image.type) else { continue }
                let label = pixelSize(of: bytes).map { "\($0.width)×\($0.height) \(image.label)" } ?? image.label
                return make(.image, preview: label, search: label)
            }
        }

        let urlName = data(TypeIdentifiers.urlName)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        if let text {
            return classifyText(text, urlName: urlName)
        }

        if let bytes = data(TypeIdentifiers.url) {
            let url = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return nil }
            return make(.link, preview: urlName ?? url, search: url + " " + (urlName ?? ""))
        }
        return nil
    }

    private static func classifyText(_ string: String, urlName: String?) -> Classification? {
        // Work on a bounded head so multi-megabyte clips stay cheap to classify.
        guard let start = string.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let head = String(string[start...].prefix(searchLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLine = !head.contains(where: \.isNewline)

        if isWebURL(head) {
            return make(.link, preview: urlName ?? head, search: head + " " + (urlName ?? ""))
        }
        if singleLine, isHexColor(head) {
            return make(.color, preview: head.uppercased(), search: head)
        }
        return make(looksLikeCode(head) ? .code : .text, preview: head, search: head)
    }

    static func looksLikeCode(_ s: String) -> Bool {
        let firstWord = s.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        if codeLeadWords.contains(firstWord) { return true }
        if codeMarkers.contains(where: { s.contains($0) }) { return true }
        if !s.contains(where: \.isWhitespace), s.count >= 24,
           s.contains(where: \.isLetter), s.contains(where: \.isNumber) {
            return true
        }
        let lines = s.split(whereSeparator: \.isNewline)
        if lines.count > 1 {
            let codeEndings = lines.filter { line in
                guard let last = line.trimmingCharacters(in: .whitespaces).last else { return false }
                return ";{}),".contains(last)
            }
            if Double(codeEndings.count) / Double(lines.count) >= 0.5 { return true }
        }
        return false
    }

    /// "#RRGGBB", or bare "RRGGBB" that mixes digits and letters ("123456" is a number,
    /// "facade" a word).
    static func isHexColor(_ s: String) -> Bool {
        if s.wholeMatch(of: /#[0-9A-Fa-f]{6}/) != nil { return true }
        guard s.wholeMatch(of: /[0-9A-Fa-f]{6}/) != nil else { return false }
        return s.contains(where: \.isNumber) && s.contains(where: \.isLetter)
    }

    /// A single http(s) URL and nothing else, surrounding whitespace aside.
    private static func isWebURL(_ s: String) -> Bool {
        let trimmed = s.prefix(searchLimit).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    /// Where the representations that make two copies "the same item" sit: the text, the image
    /// or the files, not the app-specific extras around them (VS Code adds per-copy editor data).
    static func identityPositions(of items: [[PasteboardRepresentation]], kind: ItemKind) -> [(item: Int, position: Int)] {
        func firstPosition(of types: [String], inItem index: Int) -> (item: Int, position: Int)? {
            guard items.indices.contains(index) else { return nil }
            for type in types {
                if let position = items[index].firstIndex(where: { $0.type == type }) { return (index, position) }
            }
            return nil
        }
        switch kind {
        case .file:
            return items.indices.compactMap { firstPosition(of: [TypeIdentifiers.fileURL], inItem: $0) }
        case .image:
            return firstPosition(of: imageTypes.map(\.type), inItem: 0).map { [$0] } ?? []
        case .text, .code, .link, .color:
            return firstPosition(of: [TypeIdentifiers.plainText, TypeIdentifiers.rtf, TypeIdentifiers.url], inItem: 0).map { [$0] } ?? []
        }
    }

    /// A pasteboard item's text: its plain text, else what its RTF says.
    public static func plainText(in item: [PasteboardRepresentation]) -> String? {
        if let plain = item.first(where: { $0.type == TypeIdentifiers.plainText }) {
            return String(decoding: plain.data, as: UTF8.self)
        }
        if let rtf = item.first(where: { $0.type == TypeIdentifiers.rtf }) {
            return NSAttributedString(rtf: rtf.data, documentAttributes: nil)?.string
        }
        return nil
    }

    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    private static func make(_ kind: ItemKind, preview: String, search: String) -> Classification {
        Classification(
            kind: kind,
            previewText: String(preview.prefix(previewLimit)),
            searchText: SearchNormalizer.normalize(String(search.prefix(searchLimit))))
    }
}
