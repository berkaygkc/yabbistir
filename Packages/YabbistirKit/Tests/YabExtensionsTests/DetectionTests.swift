import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabLocalization
import YabPasteboard
@testable import YabExtensions

@MainActor @Suite struct DetectionTests {
    let library: Library
    let service: ExtensionService
    let base64 = StoredTag(extensionID: "dev.yabbistir.base64", tag: "base64")

    init() throws {
        library = try Library(store: ItemStore.temporary())
        let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-det-\(UUID().uuidString)")!)
        let registry = ExtensionRegistry(builtInRoot: BuiltinFolder.root, userRoot: RegistryFixture.temporary("Extensions"),
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-det-lang-\(UUID().uuidString)")!)
        language.language = .turkish
        service = ExtensionService(registry: registry, client: ExtensionHostClient(transport: PipeTransport()) { _, _ in },
                                   library: library, settings: settings, language: language)
    }

    func ingest(_ text: String) throws -> Int64 {
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        library.didIngest(item)
        return item.id!
    }

    @Test func aBase64CopyIsTaggedOnIngest() async throws {
        let id = try ingest("SGVsbG8sIGTDvG55YQ==")
        await service.detect(itemID: id)
        #expect(try library.store.tags(ofItem: id) == [base64])
        #expect(service.item(for: id, includeImage: false)?.tags == ["dev.yabbistir.base64:base64"])
    }

    @Test func plainTextIsNotTagged() async throws {
        let id = try ingest("merhaba dünya")
        await service.detect(itemID: id)
        #expect(try library.store.tags(ofItem: id).isEmpty)
    }

    @Test func backfillTagsOldItemsOnce() async throws {
        let first = try ingest("SGVsbG8sIGTDvG55YQ==")
        let second = try ingest("eWFiYmlzdGly")
        let plain = try ingest("merhaba dünya")
        await service.backfill()
        #expect(try library.store.tags(ofItem: first) == [base64])
        #expect(try library.store.tags(ofItem: second) == [base64])
        #expect(try library.store.tags(ofItem: plain).isEmpty)
        let calls = service.validateCalls
        await service.backfill()
        #expect(service.validateCalls == calls)
    }

    @Test func previewShowsTheDecodedText() async throws {
        let id = try ingest("SGVsbG8sIGTDvG55YQ==")
        await service.detect(itemID: id)
        #expect(await service.previewSections(itemID: id) == [.code(title: "Çözülmüş hali", code: "Hello, dünya", language: nil)])
    }

    @Test func tagLabelsComeFromTheExtension() {
        #expect(service.tagLabels([base64, StoredTag(extensionID: "dev.example.gone", tag: "x")]) == ["base64"])
    }
}
