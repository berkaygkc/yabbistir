import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization

public struct PreviewInfoRow: Equatable, Sendable {
    public var label: String
    public var value: String
    /// Category dots before the names (the "Category" row).
    public var categoryColors: [CategoryColor] = []
    /// The app whose icon leads the value (the "App" row).
    public var appBundleID: String?
    /// Small grey chips in place of the value (a command's keywords).
    public var chips: [String] = []
}

/// A command's preview: what it reads and what it will paste.
public struct CommandPreview: Sendable {
    public enum Input: Sendable {
        case text(String), color(ColorValue), image(CGImage?)
    }

    public enum Output: Sendable {
        case text(String)
        /// A picture with its format and size ("PNG · 512×512").
        case image(CGImage?, label: String)
        /// Its hint is still on the way.
        case pending
        /// Nothing runs on selection: the command runs when it is pasted or copied.
        case runsWhenUsed
    }

    /// Nil for a generator.
    public var input: Input?
    public var output: Output
    public var extensionName: String
    public var icon: String
}

/// What the preview shows: the item itself on top, a quiet "Info" table below.
public struct PreviewContent: Sendable {
    public enum Body: Sendable {
        case text(String, hiddenCharacters: Int)
        case code([SyntaxToken], hiddenCharacters: Int)
        case image(CGImage?, pixelSize: CGSize?)
        case color(ColorValue)
        case link(title: String?, url: String, host: String?)
        /// Files, with a picture of the first one when it is an image.
        case files([URL], thumbnail: CGImage?)
        case command(CommandPreview)
    }

    public var itemID: Int64
    public var body: Body
    public var info: [PreviewInfoRow]
    /// Blocks extensions' detectors add, drawn under the item.
    public var extensionSections: [PreviewSection] = []
}

/// Builds previews off the main thread: payloads can be tens of megabytes, so text is capped and
/// images are decoded as thumbnails.
public enum PreviewLoader {
    /// Laying out more text than a preview can show froze the main thread (0.2 s for 50,000
    /// characters); the rest is summarised as "N more characters".
    public static let textLimit = 5_000
    public static let codeLimit = 4_000
    public static let imageLimit = 1200

    @MainActor
    public static func load(itemID: Int64, library: Library, language: AppLanguage, now: Date = Date(),
                            extensions: ExtensionCommandsProviding? = nil) async -> PreviewContent? {
        let store = library.store
        guard let item = try? store.item(id: itemID) else { return nil }
        let memberOf = Set((try? store.categoryIDs(ofItem: itemID)) ?? [])
        let categories = ((try? store.categories()) ?? []).filter { memberOf.contains($0.id ?? -1) }
        let kind = item.kind, previewText = item.previewText
        guard let decoded = await Task.detached(priority: .userInitiated, operation: { () -> Decoded? in
            guard let representations = try? store.representations(of: itemID) else { return nil }
            return decode(kind, representations, previewText: previewText)
        }).value else { return nil }

        var info: [PreviewInfoRow] = []
        func row(_ key: String, _ value: String) { info.append(PreviewInfoRow(label: L10n.string(key, language), value: value)) }
        if let name = item.sourceName {
            info.append(PreviewInfoRow(label: L10n.string("preview.app", language), value: name, appBundleID: item.sourceBundleID))
        }
        row("preview.content", L10n.string("kind.\(kind.rawValue)", language))
        if let characters = decoded.characters { row("preview.characters", NumberFormatting.count(characters, language: language)) }
        if let words = decoded.words { row("preview.words", NumberFormatting.count(words, language: language)) }
        switch decoded.body {
        case .color(let color):
            info.append(PreviewInfoRow(label: "HEX", value: color.hex))
            info.append(PreviewInfoRow(label: "RGB", value: color.rgbText))
            info.append(PreviewInfoRow(label: "HSL", value: color.hslText))
        case .link(_, _, let host?):
            row("preview.domain", host)
        case .image(_, let size?):
            row("preview.size", "\(Int(size.width))×\(Int(size.height))")
        case .files(let urls, _):
            if let size = decoded.pixelSize { row("preview.size", "\(Int(size.width))×\(Int(size.height))") }
            row("preview.location", urls.map(\.path).joined(separator: "\n"))
        default:
            break
        }
        row("preview.copied", ShortRelativeTime.string(from: item.lastCopiedAt, now: now, language: language))
        if item.device == .remote { row("preview.device", L10n.string("preview.deviceRemote", language)) }
        if !categories.isEmpty {
            info.append(PreviewInfoRow(label: L10n.string("preview.category", language),
                                       value: categories.map(\.name).joined(separator: ", "), categoryColors: categories.map(\.color)))
        }
        var content = PreviewContent(itemID: itemID, body: decoded.body, info: info)
        content.extensionSections = await extensions?.previewSections(itemID: itemID) ?? []
        return content
    }

    /// A command row's preview. A generator shows only a value made earlier for its hint (running it
    /// here would spend a different value than the one pasted); a transformer runs if it must.
    @MainActor
    public static func load(command: ExtensionCommand, rowID: Int64, subjectID: Int64?, library: Library, language: AppLanguage,
                            extensions: ExtensionCommandsProviding) async -> PreviewContent {
        var input: CommandPreview.Input?
        var inputLength: Int?
        if command.input == .item, let subjectID, let item = try? library.store.item(id: subjectID) {
            let store = library.store, kind = item.kind, previewText = item.previewText
            switch kind {
            case .color where ColorValue(hex: previewText) != nil:
                input = .color(ColorValue(hex: previewText)!)
            case .image:
                let image = await Task.detached(priority: .userInitiated) {
                    (try? store.representations(of: subjectID)).flatMap { thumbnail(from: $0, maxPixel: 600)?.image }
                }.value
                input = .image(image)
            case .file:
                // One picture copied as a file shows as the picture; other files by name.
                let picture = await Task.detached(priority: .userInitiated) { () -> (image: CGImage?, names: String) in
                    let urls = ((try? store.representations(of: subjectID)) ?? []).compactMap { item in
                        item.first { $0.type == TypeIdentifiers.fileURL }.flatMap { URL(string: String(decoding: $0.data, as: UTF8.self)) }
                    }
                    let names = urls.map(\.lastPathComponent).joined(separator: "\n")
                    guard urls.count == 1, UTType(filenameExtension: urls[0].pathExtension)?.conforms(to: .image) == true,
                          let source = CGImageSourceCreateWithURL(urls[0] as CFURL, nil) else { return (nil, names) }
                    return (thumbnail(from: source, maxPixel: 600)?.image, names)
                }.value
                input = picture.image.map { .image($0) } ?? .text(picture.names)
            default:
                let text = await Task.detached(priority: .userInitiated) {
                    plainText((try? store.representations(of: subjectID)) ?? [], previewText: previewText)
                }.value
                inputLength = text.count
                input = .text(text.count > 300 ? String(text.prefix(300)) + "…" : text)
            }
        }
        // Only what already ran (a hint) is shown: selecting a row never runs anything.
        let result = extensions.cachedOutput(of: command, subjectID: subjectID)
        var outputLength: Int?
        let output: CommandPreview.Output
        switch result {
        case .text(let text)?, .html(_, let text)?, .link(let text, _)?, ExtensionResult.none(let text?)?:
            outputLength = text.count
            output = .text(String(text.prefix(codeLimit)))
        case .image(let data, let uti, let width, let height)?:
            let image = await Task.detached(priority: .userInitiated) {
                CGImageSourceCreateWithData(data as CFData, nil).flatMap { thumbnail(from: $0, maxPixel: imageLimit)?.image }
            }.value
            let format = UTType(uti)?.preferredFilenameExtension?.uppercased() ?? uti
            output = .image(image, label: "\(format) · \(width)×\(height)")
        // Commands that make files never run ahead, so they show as runs-when-used.
        case ExtensionResult.none(nil)?, .file?, .files?, nil:
            output = extensions.runsAhead(command, subjectID: subjectID) ? .pending : .runsWhenUsed
        }

        var info: [PreviewInfoRow] = []
        func row(_ key: String, _ value: String) { info.append(PreviewInfoRow(label: L10n.string(key, language), value: value)) }
        row("preview.command.extension", command.extensionName + " · " + L10n.string("extensions.source.\(command.source.rawValue)", language))
        row("preview.command.kind", L10n.string(command.input == .none ? "preview.command.generator" : "preview.command.transformer", language))
        info.append(PreviewInfoRow(label: L10n.string("preview.command.keywords", language), value: "", chips: command.keywords))
        if let inputLength, let outputLength {
            row("preview.command.lengthLabel", L10n.string("preview.command.length", language, NumberFormatting.count(inputLength, language: language),
                                                      NumberFormatting.count(outputLength, language: language)))
        }
        let preview = CommandPreview(input: input, output: output, extensionName: command.extensionName, icon: command.icon)
        return PreviewContent(itemID: rowID, body: .command(preview), info: info)
    }

    /// An item's text: plain text, else the rich text's characters, else the stored preview line.
    static func plainText(_ items: [[PasteboardRepresentation]], previewText: String) -> String {
        func data(_ type: String) -> Data? { items.first?.first { $0.type == type }?.data }
        if let plain = data(TypeIdentifiers.plainText) { return String(decoding: plain, as: UTF8.self) }
        if let rtf = data(TypeIdentifiers.rtf), let string = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string { return string }
        return previewText
    }

    /// A downscaled image from the first image representation (PNG, JPEG, HEIC, TIFF).
    public static func thumbnail(from items: [[PasteboardRepresentation]], maxPixel: Int) -> (image: CGImage?, size: CGSize?)? {
        let types = [TypeIdentifiers.png, TypeIdentifiers.jpeg, TypeIdentifiers.heic, TypeIdentifiers.tiff]
        guard let data = types.lazy.compactMap({ type in items.first?.first { $0.type == type }?.data }).first,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    static func thumbnail(from source: CGImageSource, maxPixel: Int) -> (image: CGImage?, size: CGSize?)? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let size = (properties?[kCGImagePropertyPixelWidth] as? Int).flatMap { width in
            (properties?[kCGImagePropertyPixelHeight] as? Int).map { CGSize(width: width, height: $0) }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return (CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), size)
    }

    private struct Decoded: Sendable {
        var body: PreviewContent.Body
        var characters: Int?
        var words: Int?
        /// An image file's pixel size.
        var pixelSize: CGSize?
    }

    private static func decode(_ kind: ItemKind, _ items: [[PasteboardRepresentation]], previewText: String) -> Decoded {
        func data(_ type: String) -> Data? { items.first?.first { $0.type == type }?.data }
        func plainText() -> String { Self.plainText(items, previewText: previewText) }
        switch kind {
        case .text, .code:
            let text = plainText()
            let total = text.count
            let words = countWords(text)
            if kind == .code {
                let tokens = SyntaxHighlighter.tokens(String(text.prefix(codeLimit)))
                return Decoded(body: .code(tokens, hiddenCharacters: max(0, total - codeLimit)), characters: total, words: words)
            }
            return Decoded(body: .text(String(text.prefix(textLimit)), hiddenCharacters: max(0, total - textLimit)),
                           characters: total, words: words)
        case .color:
            if let color = ColorValue(hex: previewText) { return Decoded(body: .color(color)) }
            return Decoded(body: .text(previewText, hiddenCharacters: 0))
        case .link:
            let url = (data(TypeIdentifiers.url).map { String(decoding: $0, as: UTF8.self) } ?? plainText())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = data(TypeIdentifiers.urlName).map { String(decoding: $0, as: UTF8.self) }
            return Decoded(body: .link(title: title, url: url, host: URL(string: url)?.host))
        case .image:
            let thumbnail = thumbnail(from: items, maxPixel: imageLimit)
            return Decoded(body: .image(thumbnail?.image, pixelSize: thumbnail?.size))
        case .file:
            let urls = items.compactMap { item in
                item.first { $0.type == TypeIdentifiers.fileURL }.flatMap { URL(string: String(decoding: $0.data, as: UTF8.self)) }
            }
            // A copied screenshot or photo file previews as its picture; other files as their icon.
            guard let first = urls.first else { return Decoded(body: .files(urls, thumbnail: nil)) }
            if let source = CGImageSourceCreateWithURL(first as CFURL, nil), CGImageSourceGetCount(source) > 0,
               let picture = thumbnail(from: source, maxPixel: imageLimit) {
                return Decoded(body: .files(urls, thumbnail: picture.image), pixelSize: picture.size)
            }
            let icon = NSWorkspace.shared.icon(forFile: first.path)
            return Decoded(body: .files(urls, thumbnail: icon.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        }
    }

    private static func countWords(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(character)
            if !isSpace, !inWord { count += 1 }
            inWord = !isSpace
        }
        return count
    }
}

/// 40 px thumbnails for image rows, made off the main thread and cached for the session.
@MainActor @Observable
public final class RowThumbnails {
    @ObservationIgnored private var cache: [Int64: CGImage] = [:]
    @ObservationIgnored private var pending: Set<Int64> = []
    @ObservationIgnored private let library: Library
    /// Bumped when a thumbnail lands, so rows asking for it redraw.
    private var revision = 0

    public init(library: Library) {
        self.library = library
    }

    public func thumbnail(for itemID: Int64) -> CGImage? {
        _ = revision
        if let image = cache[itemID] { return image }
        guard !pending.contains(itemID) else { return nil }
        pending.insert(itemID)
        let store = library.store
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                (try? store.representations(of: itemID)).flatMap { PreviewLoader.thumbnail(from: $0, maxPixel: 40)?.image }
            }.value
            guard let self else { return }
            if let image { cache[itemID] = image }
            revision += 1
        }
        return nil
    }
}
