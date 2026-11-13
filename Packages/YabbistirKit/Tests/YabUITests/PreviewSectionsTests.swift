import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabLocalization
import YabTestSupport
@testable import YabUI

@MainActor @Suite struct PreviewSectionsTests {
    @Test func previewContentCarriesSections() async throws {
        let library = try Library(store: ItemStore(directory: TestScratch.url("items")))
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("SGVsbG8=".utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        library.didIngest(item)
        let fake = FakeCommands()
        fake.sections = [.code(title: "Çözülmüş hali", code: "Hello", language: nil)]
        let content = await PreviewLoader.load(itemID: item.id!, library: library, language: .turkish, extensions: fake)
        #expect(content?.extensionSections == fake.sections)
    }
}
