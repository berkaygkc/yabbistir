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
        let one = PasteSummary(historyCount: 5, boards: [board(1, 2)], totalBytes: 0)
        english.state = .ready(one, location); english.selection = PasteSelection(history: true, boards: [1])
        turkish.state = .ready(one, location); turkish.selection = PasteSelection(history: true, boards: [1])
        #expect(turkish.noteLine == "1 pinboard → 2 sabit öğe, kategori olarak gelecek")
        #expect(english.noteLine == "1 pinboard → 2 items, coming in as categories")
        english.state = .ready(PasteSummary(historyCount: 5, boards: [board(1, 2), board(2, 3)], totalBytes: 0), location)
        english.selection = PasteSelection(history: true, boards: [1, 2])
        #expect(english.noteLine == "2 pinboards → 5 items, coming in as categories")
        english.selection = PasteSelection(history: true, boards: [])
        #expect(english.noteLine == "")
    }

    @Test func statsAreGroupedAndSized() throws {
        let location = PasteLibraryLocation(folder: URL(fileURLWithPath: "/nowhere"), vendor: nil)
        let bytes: Int64 = 130_000_000
        let summary = PasteSummary(historyCount: 1_355, boards: [], totalBytes: bytes)
        let english = try makeModel(location: nil)
        let turkish = try makeModel(location: nil, language: .turkish)
        english.state = .ready(summary, location)
        turkish.state = .ready(summary, location)
        #expect(english.statsLine == "1,355 items · \(bytes.formatted(.byteCount(style: .file).locale(AppLanguage.english.locale)))")
        #expect(turkish.statsLine == "1.355 öğe · \(bytes.formatted(.byteCount(style: .file).locale(AppLanguage.turkish.locale)))")
        #expect(english.statsLine.hasPrefix("1,355 items · 130 MB"))
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
