import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import YabCore
import YabLocalization
@testable import YabUI

private func png(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@MainActor @Suite struct PreviewModelTests {
    let library: Library
    let language = AppLanguage.turkish

    init() throws {
        library = try Library(store: ItemStore.temporary())
    }

    private func ingest(_ text: String, device: DeviceKind = .local) throws -> Int64 {
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                source: SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit"), device: device, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        library.didIngest(item)
        return item.id!
    }

    private func ingestPNG(width: Int, height: Int) throws -> Int64 {
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.png, data: png(width: width, height: height))]],
                                source: nil, device: .local, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        library.didIngest(item)
        return item.id!
    }

    @Test func hugeTextIsCappedForThePreview() async throws {
        let id = try ingest(String(repeating: "a", count: 2_000_000))
        let content = try #require(await PreviewLoader.load(itemID: id, library: library, language: language))
        guard case .text(let shown, let hidden) = content.body else { Issue.record("not text"); return }
        #expect(shown.count == 5_000)
        #expect(hidden == 1_995_000)
    }

    @Test func bigImageDecodesAsAThumbnail() async throws {
        let id = try ingestPNG(width: 4000, height: 3000)
        let content = try #require(await PreviewLoader.load(itemID: id, library: library, language: language))
        guard case .image(let image, let size) = content.body else { Issue.record("not image"); return }
        #expect(max(image?.width ?? 0, image?.height ?? 0) <= 1200)
        #expect(size == CGSize(width: 4000, height: 3000))
    }

    @Test func imageRowsGetASmallThumbnail() async throws {
        let id = try ingestPNG(width: 4000, height: 3000)
        let thumbnails = RowThumbnails(library: library)
        #expect(thumbnails.thumbnail(for: id) == nil)
        let start = ContinuousClock.now
        while thumbnails.thumbnail(for: id) == nil, ContinuousClock.now - start < .seconds(10) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let image = try #require(thumbnails.thumbnail(for: id))
        #expect(max(image.width, image.height) <= 40)
    }

    @Test func imageFileShowsItsPicture() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("yab-shot-\(UUID().uuidString).png")
        try png(width: 1600, height: 1000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.fileURL, data: Data(file.absoluteString.utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        library.didIngest(item)
        let content = try #require(await PreviewLoader.load(itemID: item.id!, library: library, language: language))
        guard case .files(let urls, let thumbnail) = content.body else { Issue.record("not files"); return }
        #expect(urls == [file])
        #expect(thumbnail != nil)
        #expect(content.info.contains { $0.label == "Boyut" && $0.value == "1600×1000" })
    }

    @Test func remoteItemShowsTheDeviceRow() async throws {
        let id = try ingest("iPhone'dan", device: .remote)
        let content = try #require(await PreviewLoader.load(itemID: id, library: library, language: language))
        #expect(content.info.contains { $0.value == "iPhone · Universal Clipboard" })
    }

    @Test func textShowsCharacterAndWordCounts() async throws {
        let id = try ingest("iki kelime")
        let content = try #require(await PreviewLoader.load(itemID: id, library: library, language: language))
        #expect(content.info.contains { $0.label == "Karakter" && $0.value == "10" })
        #expect(content.info.contains { $0.label == "Kelime" && $0.value == "2" })
    }
}
