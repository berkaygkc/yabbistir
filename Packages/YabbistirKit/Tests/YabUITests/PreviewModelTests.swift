import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import YabCore
import YabExtensionKit
import YabExtensions
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

    // MARK: A source's rows

    static let entries = [SourceRow(id: "1", title: "Kodhane", subtitle: "melike@ornek.dev"), SourceRow(id: "2", title: "ornek.dev")]

    /// A synthetic vault's column, shown, its first row selected, under a panel in Turkish.
    private func vaultPanel(_ state: SourceCenter.State) throws -> (PanelViewModel, FakeSources) {
        let key = FakeSources.vault().id
        try library.syncSourceCategories([SourceCategorySeed(key: key, name: "Kasa")])
        let vault = try #require(try library.store.categories().first { $0.source == key })
        let languageStore = LanguageStore(defaults: UserDefaults(suiteName: "yab-preview-source-\(UUID().uuidString)")!)
        languageStore.language = .turkish
        let sources = FakeSources()
        sources.descriptors = [FakeSources.vault()]
        sources.states[key] = state
        let model = PanelViewModel(library: library, language: languageStore, sources: sources)
        model.reset()
        model.toggleShown(vault.id!)
        model.select(try #require(model.columns.first { $0.sourceKey == key }?.rows.first?.id), in: .category(vault.id!))
        return (model, sources)
    }

    /// The preview shows what the row already has and says the secret is never shown; opening it (space, ⌘K's Preview,
    /// a hover) asks the source for nothing, so the value is nowhere in it.
    @Test func aSourceRowPreviewNeverShowsTheSecret() throws {
        let (model, sources) = try vaultPanel(.rows(Self.entries))
        let secret = "s3cr3t-örnek"
        sources.value = .secret(secret)
        #expect(model.handle(.togglePreview) == .previewChanged)
        _ = model.handle(.togglePreview)
        _ = model.handle(.toggleActions)
        _ = model.handle(.type("önizle"))
        #expect(model.handle(.confirm(plain: false)) == .previewChanged)
        model.hoverIntent(model.selectedID!)
        #expect(model.isPreviewVisible)

        let source = try #require(model.selectedSourceRow)
        let content = PreviewLoader.load(source: source, descriptor: try #require(model.selectedSourceDescriptor), language: .turkish)
        guard case .source(let title, let subtitle, let note) = content.body else { Issue.record("not a source row"); return }
        #expect(title == "Kodhane")
        #expect(subtitle == "melike@ornek.dev")
        #expect(note == "Şifre hiçbir zaman gösterilmez.")
        #expect(content.info.isEmpty)
        #expect(content.extensionSections.isEmpty)
        #expect(content.actionHints == [BarLabel(title: "Şifreyi yapıştır", keys: ["↵"])])
        let shown = [title, subtitle ?? "", note ?? ""] + (content.actionHints ?? []).map(\.title)
        #expect(!shown.contains { $0.contains(secret) })
        #expect(sources.runs.isEmpty)

        // In English, with the source's own word; a source without a secret says nothing about one.
        let english = PreviewLoader.load(source: source, descriptor: SourceDescriptor(extensionID: "dev.example.kasa", extensionName: "Vault",
            sourceID: "vault", title: "Vault", sensitive: true, actions: [SourceActionDescriptor(id: "password", kind: .secret,
                                                                                                    title: "Paste password", label: "Password")]),
                                         language: .english)
        guard case .source(_, _, let englishNote) = english.body else { Issue.record("not a source row"); return }
        #expect(englishNote == "Password is never shown.")
        let notes = SourceDescriptor(extensionID: "dev.example.notes", extensionName: "Notlar", sourceID: "notes", title: "Notlar",
                                     sensitive: false, actions: [SourceActionDescriptor(id: "text", kind: .text, title: "Notu yapıştır",
                                                                                        label: "Not")])
        guard case .source(_, _, let none) = PreviewLoader.load(source: .entry(key: notes.id, row: Self.entries[1]), descriptor: notes,
                                                                language: .turkish).body else { Issue.record("not a source row"); return }
        #expect(none == nil)
        #expect(sources.runs.isEmpty)
    }

    /// The locked row's preview: the line to run in Terminal and what to do after; ⌘C copies the command.
    @Test func theLockedPreviewShowsTheCommand() throws {
        let command = "kasa login --trust <e-posta>"
        let (model, sources) = try vaultPanel(.locked(message: "Kasa kilitli", command: command))
        #expect(model.handle(.togglePreview) == .previewChanged)
        #expect(model.isPreviewVisible)
        let descriptor = try #require(model.selectedSourceDescriptor)
        let content = PreviewLoader.load(source: try #require(model.selectedSourceRow), descriptor: descriptor, language: .turkish)
        guard case .lockedSource(let shown) = content.body else { Issue.record("not the locked row"); return }
        #expect(shown == command)
        #expect(content.info.isEmpty)
        #expect(content.actionHints == [BarLabel(title: "Komutu kopyala", keys: ["⌘", "C"])])
        #expect(L10n.string("preview.source.runInTerminal", .turkish) == "Terminal’de çalıştır")
        #expect(L10n.string("preview.source.reopen", .turkish) == "Giriş yaptıktan sonra paneli yeniden aç.")
        #expect(L10n.string("preview.source.runInTerminal", .english) == "Run in Terminal")
        #expect(L10n.string("preview.source.reopen", .english) == "After you sign in, open the panel again.")

        // Without a command there is nothing to copy.
        let bare = PreviewLoader.load(source: .locked(key: descriptor.id, message: "Kasa kilitli", command: nil), descriptor: descriptor,
                                      language: .turkish)
        guard case .lockedSource(nil) = bare.body else { Issue.record("not the bare locked row"); return }
        #expect(bare.actionHints == [])
        #expect(sources.runs.isEmpty)
    }
}
