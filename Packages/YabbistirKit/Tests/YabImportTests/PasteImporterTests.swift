import Foundation
import Testing
import YabCore
import YabImportTestSupport
@testable import YabImport

private typealias L = SyntheticPasteLibrary
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func text(_ s: String) -> [[(String, String)]] { [[("public.utf8-plain-text", s)]] }

private func open(_ items: [L.Item], boards: [L.Board] = [], apps: [L.App] = []) throws -> PasteLibrary {
    let folder = try tempFolder()
    try L.make(in: folder, items: items, boards: boards, apps: apps)
    return try PasteLibrary.open(PasteLibraryLocation(folder: folder, vendor: nil))
}

private func importer(_ store: ItemStore, ignored: Set<String> = []) -> PasteImporter {
    PasteImporter(store: store, ignoredApps: ignored, now: now)
}

private let everything = PasteSelection(history: true, boards: [7])

/// 3 history items and a 2-item board (b-top is shown first).
private func sample() throws -> PasteLibrary {
    try open([
        L.Item(externalID: "h1", createdAt: 100, timestamp: 110, payload: .plain(text("one"))),
        L.Item(externalID: "h2", createdAt: 200, timestamp: 210, payload: .plain(text("two"))),
        L.Item(externalID: "h3", createdAt: 300, timestamp: 310, payload: .plain(text("three"))),
        L.Item(externalID: "b-top", createdAt: 10, timestamp: 20, board: 7, order: 1, payload: .plain(text("pinned top"))),
        L.Item(externalID: "b-low", createdAt: 30, timestamp: 40, board: 7, order: 2, payload: .plain(text("pinned low"))),
    ], boards: [.init(pk: 7, name: "Links")])
}

@Suite struct PasteImporterTests {
    @Test func importsHistoryAndBoards() throws {
        let store = try ItemStore.temporary()
        let library = try sample()
        defer { library.close() }
        let report = try importer(store).run(library, selection: everything) { _ in }
        #expect(report.added == 5 && report.failed == 0 && report.skipped == 0)
        #expect(report.categoriesCreated == 1)
        let category = try #require(try store.categories().first)
        #expect(category.name == "Links" && category.visibility == .onSelect && category.source == nil)
        let previews = try store.itemIDs(inCategory: category.id!).compactMap { try store.item(id: $0)?.previewText }
        #expect(previews == ["pinned top", "pinned low"])
        let inHistory = try store.history(limit: 100).filter(\.inHistory).map(\.previewText)
        #expect(Set(inHistory) == ["one", "two", "three"])
        let item = try #require(try store.history(limit: 100).first { $0.previewText == "one" })
        #expect(item.lastCopiedAt == Date(timeIntervalSinceReferenceDate: 110))
        #expect(item.lastUsedAt == now)
    }

    @Test func importingAgainAddsNothing() throws {
        let store = try ItemStore.temporary()
        let library = try sample()
        defer { library.close() }
        _ = try importer(store).run(library, selection: everything) { _ in }
        let again = try importer(store).run(library, selection: everything) { _ in }
        #expect(again.added == 0 && again.skipped == 5 && again.categoriesCreated == 0)
    }

    @Test func aBoardJoinsTheSameNamedCategory() throws {
        let store = try ItemStore.temporary()
        let existing = try store.createCategory(name: "LINKS", color: .sage, visibility: .always)
        let library = try sample()
        defer { library.close() }
        let report = try importer(store).run(library, selection: everything) { _ in }
        #expect(report.categoriesCreated == 0)
        #expect(try store.categories().count == 1)
        #expect(try store.itemIDs(inCategory: existing.id!).count == 2)
    }

    @Test func ignoredAppsAndConcealedItemsStayOut() throws {
        let store = try ItemStore.temporary()
        let library = try open([
            L.Item(externalID: "ok", createdAt: 1, timestamp: 2, app: 1, payload: .plain(text("fine"))),
            L.Item(externalID: "ignored", createdAt: 1, timestamp: 3, app: 2, payload: .plain(text("from a vault"))),
            L.Item(externalID: "secret", createdAt: 1, timestamp: 4,
                   payload: .plain([[("public.utf8-plain-text", "hunter2"), ("org.nspasteboard.ConcealedType", "")]])),
        ], apps: [.init(pk: 1, bundleID: "dev.ornek.app", name: "Ornek"), .init(pk: 2, bundleID: "dev.ornek.vault", name: "Vault")])
        defer { library.close() }
        let report = try importer(store, ignored: ["dev.ornek.vault"]).run(library, selection: PasteSelection(history: true, boards: [])) { _ in }
        #expect(report.added == 1 && report.skipped == 2)
        #expect(try store.history(limit: 10).map(\.previewText) == ["fine"])
    }

    @Test func anUndecodableItemFallsBackToItsTitle() throws {
        let store = try ItemStore.temporary()
        let library = try open([
            L.Item(externalID: "titled", title: "Meeting notes", createdAt: 1, timestamp: 2, payload: .garbage),
            L.Item(externalID: "untitled", createdAt: 1, timestamp: 3, payload: .garbage),
            L.Item(externalID: "empty", title: "  ", createdAt: 1, timestamp: 4, payload: .none),
        ])
        defer { library.close() }
        let report = try importer(store).run(library, selection: PasteSelection(history: true, boards: [])) { _ in }
        #expect(report.added == 1 && report.failed == 2)
        #expect(try store.history(limit: 10).map(\.previewText) == ["Meeting notes"])
    }

    @Test func onlySelectedPartsComeIn() throws {
        let store = try ItemStore.temporary()
        let library = try sample()
        defer { library.close() }
        let report = try importer(store).run(library, selection: PasteSelection(history: false, boards: [7])) { _ in }
        #expect(report.added == 2 && report.categoriesCreated == 1)
        #expect(try store.history(limit: 10).filter(\.inHistory).isEmpty)
    }

    @Test func aLargeImportReportsProgressSparsely() throws {
        let store = try ItemStore.temporary()
        let library = try open((0..<600).map {
            L.Item(externalID: "n\($0)", createdAt: Double($0), timestamp: Double($0), payload: .plain(text("item \($0)")))
        })
        defer { library.close() }
        let calls = Calls()
        _ = try importer(store).run(library, selection: PasteSelection(history: true, boards: [])) { calls.add($0) }
        let all = calls.all
        #expect(all.count <= 15)
        #expect(all.last?.done == 600 && all.last?.total == 600)
        #expect(all.map(\.done) == all.map(\.done).sorted())
    }

    @Test func kindsAreCounted() throws {
        let store = try ItemStore.temporary()
        let library = try open([
            L.Item(externalID: "a", createdAt: 1, timestamp: 1, payload: .plain(text("just words"))),
            L.Item(externalID: "b", createdAt: 1, timestamp: 2, payload: .plain(text("more words"))),
            L.Item(externalID: "c", createdAt: 1, timestamp: 3, payload: .plain(text("https://example.com/page"))),
            L.Item(externalID: "d", createdAt: 1, timestamp: 4, payload: .plain(text("#FF8800"))),
        ])
        defer { library.close() }
        let report = try importer(store).run(library, selection: PasteSelection(history: true, boards: [])) { _ in }
        #expect(report.kinds == [.text: 2, .link: 1, .color: 1])
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ImportProgress] = []
    func add(_ p: ImportProgress) { lock.lock(); values.append(p); lock.unlock() }
    var all: [ImportProgress] { lock.lock(); defer { lock.unlock() }; return values }
}
