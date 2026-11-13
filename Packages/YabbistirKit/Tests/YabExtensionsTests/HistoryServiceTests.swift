import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabLocalization
import YabPasteboard
import YabTestSupport
@testable import YabExtensions

/// Records where the history items were built.
private final class BuildThreads: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: [Bool] = []
    func record() { lock.withLock { onMain.append(Thread.isMainThread) } }
    var all: [Bool] { lock.withLock { onMain } }
}

@MainActor @Suite struct HistoryServiceTests {
    let library: Library
    let service: ExtensionService

    init() throws {
        library = try Library(store: ItemStore(directory: TestScratch.url("items")))
        let settings = ExtensionSettings(defaults: TestScratch.defaults("yab-hist"))
        let registry = ExtensionRegistry(builtInRoot: BuiltinFolder.root, userRoot: RegistryFixture.temporary("Extensions"),
                                         dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        let language = LanguageStore(defaults: TestScratch.defaults("yab-hist-lang"), preferredLanguages: ["en"])
        service = ExtensionService(registry: registry, client: ExtensionHostClient(transport: PipeTransport()) { _, _ in },
                                   library: library, settings: settings, language: language)
    }

    @discardableResult
    private func ingest(_ text: String) throws -> Int64 {
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        let item = try #require(try library.store.ingest(clip)).item
        library.didIngest(item)
        return item.id!
    }

    @Test func historyTextIsCappedAt64KB() async throws {
        // 200 KB of 3-byte characters: 65 536 is not a multiple of 3, so a cut at the limit lands mid-scalar.
        try ingest(String(repeating: "€", count: 70_000))
        let items = await service.historyItems(recent: 5)
        let text = try #require(items.first?.text)
        #expect(text.utf8.count <= 65_536)
        #expect(text == String(repeating: "€", count: 21_845))
        #expect(String(validatingUTF8: Array(text.utf8CString)) == text)
        #expect(items.first?.truncated == true)
    }

    @Test func aShortItemIsNotMarkedTruncated() async throws {
        try ingest("merhaba")
        let items = await service.historyItems(recent: 5)
        #expect(items.first?.text == "merhaba")
        #expect(items.first?.truncated != true)
    }

    @Test func historyIsBuiltOffTheMainActor() async throws {
        let threads = BuildThreads()
        service.historyBuildObserver = { threads.record() }
        try ingest("bir")
        try ingest("iki")
        _ = await service.historyItems(recent: 5)
        _ = await service.historyItems(matching: "bir", limit: 5)
        #expect(threads.all.count == 3)
        #expect(threads.all.allSatisfy { !$0 })
    }
}
