import Foundation
import Testing
import YabCore
import YabImport
import YabImportTestSupport
import YabLocalization
@testable import YabUI

@MainActor
private final class Counter {
    var reloads = 0
    var quits = 0
    var running = true
}

@MainActor
private func makeModel(location: PasteLibraryLocation?, counter: Counter = Counter(), language: AppLanguage = .english,
                       store: ItemStore? = nil) throws -> ImportModel {
    let languages = LanguageStore(defaults: UserDefaults(suiteName: "yab-import-\(UUID().uuidString)")!)
    languages.language = language
    return ImportModel(
        store: try store ?? ItemStore.temporary(), reload: { counter.reloads += 1 }, ignoredApps: { [] },
        locate: { location }, otherAppRunning: { counter.running },
        quitOtherApp: { counter.quits += 1; counter.running = false }, language: languages)
}

private func syntheticLocation() throws -> PasteLibraryLocation {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("imp-ui-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func text(_ s: String) -> SyntheticPasteLibrary.Payload { .plain([[("public.utf8-plain-text", s)]]) }
    try SyntheticPasteLibrary.make(in: folder, items: [
        .init(externalID: "h1", createdAt: 100, timestamp: 110, payload: text("one")),
        .init(externalID: "h2", createdAt: 200, timestamp: 210, payload: text("two")),
        .init(externalID: "b1", createdAt: 10, timestamp: 20, board: 7, order: 1, payload: text("pinned a")),
        .init(externalID: "b2", createdAt: 30, timestamp: 40, board: 7, order: 2, payload: text("pinned b")),
    ], boards: [.init(pk: 7, name: "Links")])
    return PasteLibraryLocation(folder: folder, vendor: nil)
}

private func board(_ id: Int64, _ count: Int) -> PasteBoard { PasteBoard(id: id, name: "B\(id)", count: count) }

@MainActor @Suite struct ImportModelTests {
    @Test func noLibraryMeansUnavailable() async throws {
        let model = try makeModel(location: nil)
        await model.scan()
        #expect(model.state == .unavailable)
    }

    @Test func scanShowsTheSummaryAndSelectsEverything() async throws {
        let location = try syntheticLocation()
        let model = try makeModel(location: location)
        #expect(model.state == .scanning)
        await model.scan()
        guard case .ready(let summary, let found) = model.state else { Issue.record("not ready: \(model.state)"); return }
        #expect(found == location)
        #expect(summary.historyCount == 2 && summary.boards.map(\.id) == [7])
        #expect(model.selection == PasteSelection(history: true, boards: [7]))
        #expect(model.selectedBoardItemCount == 2)
    }

    @Test func importRunsOffTheMainActorAndReloadsOnce() async throws {
        let counter = Counter()
        let store = try ItemStore.temporary()
        let model = try makeModel(location: try syntheticLocation(), counter: counter, store: store)
        await model.scan()
        model.start()
        await model.finished()
        guard case .done(let report) = model.state else { Issue.record("not done: \(model.state)"); return }
        #expect(report.added == 4 && report.failed == 0 && report.categoriesCreated == 1)
        #expect(counter.reloads == 1)
        #expect(model.resultLine == "4 new items added.")
        #expect(model.failedLine == nil)
    }

    @Test func theNoteCountsSelectedBoards() throws {
        let location = PasteLibraryLocation(folder: URL(fileURLWithPath: "/nowhere"), vendor: nil)
        let english = try makeModel(location: nil)
        let turkish = try makeModel(location: nil, language: .turkish)
        func set(_ boards: [PasteBoard], _ chosen: Set<Int64>) {
            for model in [english, turkish] {
                model.state = .ready(PasteSummary(historyCount: 5, boards: boards, totalBytes: 0), location)
                model.selection = PasteSelection(history: true, boards: chosen)
            }
        }
        set([board(1, 1)], [1])
        #expect(english.noteLine == "1 pinboard → 1 item, coming in as categories")
        #expect(turkish.noteLine == "1 pinboard → 1 sabit öğe, kategori olarak gelecek")
        set([board(1, 2)], [1])
        #expect(english.noteLine == "1 pinboard → 2 items, coming in as categories")
        #expect(turkish.noteLine == "1 pinboard → 2 sabit öğe, kategori olarak gelecek")
        set([board(1, 100), board(2, 140)], [1, 2])
        #expect(english.noteLine == "2 pinboards → 240 items, coming in as categories")
        #expect(turkish.noteLine == "2 pinboard → 240 sabit öğe, kategori olarak gelecek")
        set([board(1, 100)], [])
        #expect(english.noteLine == "")
    }

    @Test func statsAreGroupedAndSized() throws {
        let location = PasteLibraryLocation(folder: URL(fileURLWithPath: "/nowhere"), vendor: nil)
        let bytes: Int64 = 130_000_000
        let english = try makeModel(location: nil)
        let turkish = try makeModel(location: nil, language: .turkish)
        func size(_ language: AppLanguage) -> String { bytes.formatted(.byteCount(style: .file).locale(language.locale)) }
        for (count, en, tr) in [(1_355, "1,355 items", "1.355 öğe"), (1, "1 item", "1 öğe"), (0, "0 items", "0 öğe")] {
            let summary = PasteSummary(historyCount: count, boards: [], totalBytes: bytes)
            english.state = .ready(summary, location)
            turkish.state = .ready(summary, location)
            #expect(english.statsLine == "\(en) · \(size(.english))")
            #expect(turkish.statsLine == "\(tr) · \(size(.turkish))")
        }
        english.state = .ready(PasteSummary(historyCount: 1_355, boards: [], totalBytes: bytes), location)
        #expect(english.statsLine.hasPrefix("1,355 items · 130 MB"))
        #expect(english.itemsPhrase(1) == "1 item" && turkish.itemsPhrase(2) == "2 öğe")
    }

    @Test func theSourceLineShowsVendorAndFolder() throws {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let folder = support.appendingPathComponent("com.example.lib", isDirectory: true)
        let summary = PasteSummary(historyCount: 1, boards: [], totalBytes: 0)
        let model = try makeModel(location: nil)
        model.state = .ready(summary, PasteLibraryLocation(folder: folder, vendor: "Setapp"))
        #expect(model.sourceLine == "Setapp · ~/Library/Application Support")
        model.state = .ready(summary, PasteLibraryLocation(folder: folder, vendor: nil))
        #expect(model.sourceLine == "~/Library/Application Support")
        #expect(model.sourceName == "Paste")
    }

    @Test func anotherAppRunningIsOfferedToQuit() throws {
        let counter = Counter()
        let model = try makeModel(location: nil, counter: counter)
        #expect(model.otherAppRunning)
        model.quitOtherApp()
        #expect(counter.quits == 1)
        #expect(!model.otherAppRunning)
    }

    @Test func aFailedOpenShowsFailed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("imp-ui-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = try makeModel(location: PasteLibraryLocation(folder: folder, vendor: nil))
        await model.scan()
        #expect(model.state == .failed)
    }
}
