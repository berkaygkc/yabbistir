import Foundation
import Testing
import YabCore
import YabImportTestSupport
import YabTestSupport
@testable import YabImport

private typealias L = SyntheticPasteLibrary
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func tempFolder() throws -> URL {
    let url = TestScratch.url("imp")
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
        let store = try ItemStore(directory: TestScratch.url("items"))
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
        let store = try ItemStore(directory: TestScratch.url("items"))
        let library = try sample()
        defer { library.close() }
        _ = try importer(store).run(library, selection: everything) { _ in }
        let again = try importer(store).run(library, selection: everything) { _ in }
        #expect(again.added == 0 && again.skipped == 5 && again.categoriesCreated == 0)
    }

    @Test func aBoardJoinsTheSameNamedCategory() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let existing = try store.createCategory(name: "LINKS", color: .sage, visibility: .always)
        let library = try sample()
        defer { library.close() }
        let report = try importer(store).run(library, selection: everything) { _ in }
        #expect(report.categoriesCreated == 0)
        #expect(try store.categories().count == 1)
        #expect(try store.itemIDs(inCategory: existing.id!).count == 2)
    }

    @Test func ignoredAppsAndConcealedItemsStayOut() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
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
        let store = try ItemStore(directory: TestScratch.url("items"))
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
        let store = try ItemStore(directory: TestScratch.url("items"))
        let library = try sample()
        defer { library.close() }
        let report = try importer(store).run(library, selection: PasteSelection(history: false, boards: [7])) { _ in }
        #expect(report.added == 2 && report.categoriesCreated == 1)
        #expect(try store.history(limit: 10).filter(\.inHistory).isEmpty)
    }

    @Test func aLargeImportReportsProgressSparsely() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let library = try open((0..<600).map {
            L.Item(externalID: "n\($0)", createdAt: Double($0), timestamp: Double($0), payload: .plain(text("item \($0)")))
        })
        defer { library.close() }
        let calls = Calls()
        let slow = PasteImporter(store: store, ignoredApps: [], now: now,
                                 throttle: .init(step: 50, interval: .seconds(3600)))
        _ = try slow.run(library, selection: PasteSelection(history: true, boards: [])) { calls.add($0) }
        let all = calls.all
        #expect(all.count == 13)
        #expect(all.last?.done == 600 && all.last?.total == 600)
        #expect(all.map(\.done) == all.map(\.done).sorted())
        #expect(all.last?.kinds == [.text: 600])
    }

    @Test func theTimeTriggerFiresWhenTheIntervalIsTiny() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let library = try open((0..<20).map {
            L.Item(externalID: "n\($0)", createdAt: Double($0), timestamp: Double($0), payload: .plain(text("item \($0)")))
        })
        defer { library.close() }
        let calls = Calls()
        let eager = PasteImporter(store: store, ignoredApps: [], now: now, throttle: .init(step: 1000, interval: .zero))
        _ = try eager.run(library, selection: PasteSelection(history: true, boards: [])) { calls.add($0) }
        #expect(calls.all.count == 20)
    }

    @Test func anEmptyBoardNameBecomesPinboardN() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let library = try open([
            L.Item(externalID: "b", createdAt: 1, timestamp: 1, board: 7, order: 1, payload: .plain(text("pinned"))),
        ], boards: [.init(pk: 7, name: "   ")])
        defer { library.close() }
        let report = try importer(store).run(library, selection: PasteSelection(history: false, boards: [7])) { _ in }
        #expect(report.added == 1 && report.failed == 0)
        #expect(try store.categories().map(\.name) == ["Pinboard 7"])
    }

    /// A pinboard item that cannot be filed (its category went away mid-run) is not imported at all: it counts as
    /// failed, leaves nothing in History, the other boards complete, and the next run brings it.
    @Test func aBoardItemThatCannotBeFiledComesInNextTime() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let library = try open([
            L.Item(externalID: "h", createdAt: 1, timestamp: 1, payload: .plain(text("history"))),
            L.Item(externalID: "a", createdAt: 1, timestamp: 2, board: 7, order: 1, payload: .plain(text("board seven"))),
            L.Item(externalID: "b", createdAt: 1, timestamp: 3, board: 8, order: 1, payload: .plain(text("board eight"))),
        ], boards: [.init(pk: 7, name: "Seven"), .init(pk: 8, name: "Eight")])
        defer { library.close() }
        let selection = PasteSelection(history: true, boards: [7, 8])
        let flaky = PasteImporter(store: store, ignoredApps: [], now: now, throttle: .init(), beforeItem: { item in
            guard item.boardID == 7, let seven = try store.categories().first(where: { $0.name == "Seven" }) else { return }
            _ = try store.deleteCategory(id: seven.id!)
        })
        let report = try flaky.run(library, selection: selection) { _ in }
        #expect(report.failed == 1 && report.added == 2 && report.categoriesCreated == 1)
        #expect(try store.categories().map(\.name) == ["Eight"])
        #expect(try store.history(limit: 10).map(\.previewText).sorted() == ["board eight", "history"])
        #expect(try store.history(limit: 10).filter(\.inHistory).map(\.previewText) == ["history"])

        let again = try importer(store).run(library, selection: selection) { _ in }
        #expect(again.added == 1 && again.skipped == 2 && again.categoriesCreated == 1)
        let seven = try #require(try store.categories().first { $0.name == "Seven" })
        #expect(try store.itemIDs(inCategory: seven.id!).compactMap { try store.item(id: $0)?.previewText } == ["board seven"])
        #expect(try store.history(limit: 10).filter(\.inHistory).map(\.previewText) == ["history"])
    }

    @Test func aMergedBoardItemStaysInHistoryAndJoinsTheCategory() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let existing = try #require(try store.ingest(CapturedClip(
            items: [[PasteboardRepresentation(type: "public.utf8-plain-text", data: Data("already here".utf8))]],
            source: nil, device: .local, capturedAt: now)))
        let library = try open([
            L.Item(externalID: "b", createdAt: 1, timestamp: 1, board: 7, order: 1, payload: .plain(text("already here"))),
        ], boards: [.init(pk: 7, name: "Links")])
        defer { library.close() }
        let report = try importer(store).run(library, selection: PasteSelection(history: false, boards: [7])) { _ in }
        #expect(report.merged == 1 && report.added == 0)
        #expect(try store.item(id: existing.item.id!)?.inHistory == true)
        let category = try #require(try store.categories().first)
        #expect(try store.itemIDs(inCategory: category.id!) == [existing.item.id!])
    }

    @Test func aSameNamedSourceCategoryIsNotJoined() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.syncSourceCategories([SourceCategorySeed(key: "ext/src", name: "Links")])
        let library = try sample()
        defer { library.close() }
        let report = try importer(store).run(library, selection: everything) { _ in }
        #expect(report.categoriesCreated == 1)
        let all = try store.categories()
        #expect(all.count == 2)
        let source = try #require(all.first { $0.isSource })
        #expect(try store.itemIDs(inCategory: source.id!).isEmpty)
    }

    @Test func categoriesCreatedCountsOnlyNewOnes() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.createCategory(name: "Links", color: .sage)
        let library = try open([
            L.Item(externalID: "a", createdAt: 1, timestamp: 1, board: 7, order: 1, payload: .plain(text("one"))),
            L.Item(externalID: "b", createdAt: 1, timestamp: 2, board: 8, order: 1, payload: .plain(text("two"))),
        ], boards: [.init(pk: 7, name: "Links"), .init(pk: 8, name: "Fresh")])
        defer { library.close() }
        let report = try importer(store).run(library, selection: PasteSelection(history: false, boards: [7, 8])) { _ in }
        #expect(report.categoriesCreated == 1)
        #expect(try store.categories().count == 2)
    }

    @Test func aConcealedTypeOnALaterItemSkipsTheWholeItem() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let library = try open([
            L.Item(externalID: "s", createdAt: 1, timestamp: 1, payload: .plain([
                [("public.utf8-plain-text", "first")], [("org.nspasteboard.TransientType", "")]])),
        ])
        defer { library.close() }
        let report = try importer(store).run(library, selection: PasteSelection(history: true, boards: [])) { _ in }
        #expect(report.skipped == 1 && report.added == 0)
        #expect(try store.history(limit: 10).isEmpty)
    }

    /// A run that stops partway through the pinboards (a quit, a crash, an unreadable page) loses none of them: the
    /// next run files every item, in order, and keeps the pinned-only ones out of History.
    @Test func anInterruptedRunStillFilesEveryPinboardItemNextTime() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let library = try open([
            L.Item(externalID: "h", createdAt: 1, timestamp: 1, payload: .plain(text("history"))),
            L.Item(externalID: "a1", createdAt: 1, timestamp: 2, board: 7, order: 1, payload: .plain(text("first"))),
            L.Item(externalID: "a2", createdAt: 1, timestamp: 3, board: 7, order: 2, payload: .plain(text("second"))),
            L.Item(externalID: "a3", createdAt: 1, timestamp: 4, board: 7, order: 3, payload: .plain(text("third"))),
            L.Item(externalID: "b1", createdAt: 1, timestamp: 5, board: 8, order: 1, payload: .plain(text("other board"))),
        ], boards: [.init(pk: 7, name: "Links"), .init(pk: 8, name: "Notes")])
        defer { library.close() }
        let selection = PasteSelection(history: true, boards: [7, 8])
        struct Quit: Error {}
        let countdown = Countdown(passes: 2)
        let interrupted = PasteImporter(store: store, ignoredApps: [], now: now, throttle: .init(), beforeItem: { item in
            if item.boardID != nil, countdown.expired() { throw Quit() }
        })
        #expect(throws: Quit.self) { _ = try interrupted.run(library, selection: selection) { _ in } }

        _ = try importer(store).run(library, selection: selection) { _ in }
        func previews(_ name: String) throws -> [String] {
            let category = try #require(try store.categories().first { $0.name == name })
            return try store.itemIDs(inCategory: category.id!).compactMap { try store.item(id: $0)?.previewText }
        }
        #expect(try store.categories().count == 2)
        #expect(try previews("Links") == ["first", "second", "third"])
        #expect(try previews("Notes") == ["other board"])
        #expect(try store.history(limit: 10).filter(\.inHistory).map(\.previewText) == ["history"])
    }

    /// A pinboard whose items all stay out (an ignored app, or imported before and deleted since) leaves no empty
    /// category behind.
    @Test func aPinboardWithNothingNewLeavesNoEmptyCategory() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let library = try open([
            L.Item(externalID: "a", createdAt: 1, timestamp: 1, board: 7, order: 1, app: 1, payload: .plain(text("from a vault"))),
            L.Item(externalID: "b", createdAt: 1, timestamp: 2, board: 8, order: 1, payload: .plain(text("kept"))),
        ], boards: [.init(pk: 7, name: "Vault"), .init(pk: 8, name: "Notes")],
           apps: [.init(pk: 1, bundleID: "dev.ornek.vault", name: "Vault")])
        defer { library.close() }
        let selection = PasteSelection(history: false, boards: [7, 8])
        let report = try importer(store, ignored: ["dev.ornek.vault"]).run(library, selection: selection) { _ in }
        #expect(report.categoriesCreated == 1 && report.skipped == 1)
        #expect(try store.categories().map(\.name) == ["Notes"])

        // Deleted after the import: running it again brings nothing back, not even an empty column.
        let notes = try #require(try store.categories().first)
        _ = try store.deleteCategory(id: notes.id!)
        let again = try importer(store, ignored: ["dev.ornek.vault"]).run(library, selection: selection) { _ in }
        #expect(again.categoriesCreated == 0)
        #expect(try store.categories().isEmpty)
    }

    /// Rows with a raw-byte identifier, no identifier at all, or no creation date all come in, each as its own item.
    @Test func oddRowsImportAsDistinctItems() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let bytes = Data([0xFF, 0xFE, 0x00, 0x80, 0xC3, 0x28, 0xA0, 0xA1, 0xE2, 0x28, 0xA1, 0xF0, 0x28, 0x8C, 0xBC, 0x9F])
        let library = try open([
            L.Item(externalID: nil, identifierBytes: bytes, createdAt: 1, timestamp: 2, payload: .plain(text("raw bytes"))),
            L.Item(externalID: nil, createdAt: 1, timestamp: 3, payload: .plain(text("no id"))),
            L.Item(externalID: nil, createdAt: 1, timestamp: 4, payload: .plain(text("no id either"))),
            L.Item(externalID: "undated", createdAt: nil, timestamp: 5, payload: .plain(text("no created date"))),
        ])
        defer { library.close() }
        let report = try importer(store).run(library, selection: PasteSelection(history: true, boards: [])) { _ in }
        #expect(report.added == 4 && report.skipped == 0 && report.failed == 0)
        let items = try store.history(limit: 10)
        #expect(Set(items.map(\.previewText)) == ["raw bytes", "no id", "no id either", "no created date"])
        let undated = try #require(items.first { $0.previewText == "no created date" })
        #expect(undated.firstCopiedAt == Date(timeIntervalSinceReferenceDate: 5))
        let again = try importer(store).run(library, selection: PasteSelection(history: true, boards: [])) { _ in }
        #expect(again.added == 0 && again.skipped == 4)
    }

    @Test func kindsAreCounted() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
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

/// Lets `passes` calls through, then reports expiry on every later one.
private final class Countdown: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    init(passes: Int) { left = passes }
    func expired() -> Bool {
        lock.lock(); defer { lock.unlock() }
        left -= 1
        return left < 0
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ImportProgress] = []
    func add(_ p: ImportProgress) { lock.lock(); values.append(p); lock.unlock() }
    var all: [ImportProgress] { lock.lock(); defer { lock.unlock() }; return values }
}
