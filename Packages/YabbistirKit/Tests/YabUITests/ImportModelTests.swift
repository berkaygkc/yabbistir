import Foundation
import Testing
import YabCore
import YabImport
import YabImportTestSupport
import YabLocalization
import YabTestSupport
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
    let languages = LanguageStore(defaults: TestScratch.defaults("yab-import"), preferredLanguages: ["en"])
    languages.language = language
    return ImportModel(
        store: try store ?? ItemStore(directory: TestScratch.url("items")), reload: { counter.reloads += 1 }, ignoredApps: { [] },
        locate: { location }, otherAppRunning: { counter.running },
        quitOtherApp: { counter.quits += 1; counter.running = false }, language: languages)
}

private func syntheticLocation() throws -> PasteLibraryLocation {
    let folder = TestScratch.url("imp-ui")
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
        let store = try ItemStore(directory: TestScratch.url("items"))
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

    /// The first-run card sets the count large and the unit with the size under it.
    @Test func theCardCountsEverythingAndNamesItsUnit() throws {
        let location = PasteLibraryLocation(folder: URL(fileURLWithPath: "/nowhere"), vendor: nil)
        let english = try makeModel(location: nil)
        let turkish = try makeModel(location: nil, language: .turkish)
        let summary = PasteSummary(historyCount: 1_000, boards: [board(1, 300), board(2, 55)], totalBytes: 130_000_000)
        english.state = .ready(summary, location)
        turkish.state = .ready(summary, location)
        #expect(english.libraryItemCount == 1_355)
        #expect(english.unitLine.hasPrefix("items · 130") && turkish.unitLine.hasPrefix("öğe · 130"))
        english.state = .ready(PasteSummary(historyCount: 1, boards: [], totalBytes: 0), location)
        #expect(english.unitLine.hasPrefix("item · "))
        english.state = .scanning
        #expect(english.libraryItemCount == 0 && english.unitLine.isEmpty)
    }

    @Test func theSourceLineShowsVendorAndFolder() throws {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let folder = support.appendingPathComponent("com.example.lib", isDirectory: true)
        let summary = PasteSummary(historyCount: 1, boards: [], totalBytes: 0)
        let model = try makeModel(location: nil)
        model.state = .ready(summary, PasteLibraryLocation(folder: folder, vendor: "Ornek"))
        #expect(model.sourceLine == "Ornek · ~/Library/Application Support")
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

    /// Two scans in flight: the first makes the library ready and an import starts; the second, arriving late, leaves
    /// the import (and the choice it was started with) alone.
    @Test func aLateScanNeverOverridesAnImport() async throws {
        let model = try makeModel(location: try syntheticLocation())
        let gates = Gates()
        model.summarize = { location in
            await gates.pass()
            guard let library = try? PasteLibrary.open(location) else { return nil }
            defer { library.close() }
            return try? library.summary()
        }
        let first = Task { await model.scan() }
        await gates.waitForArrivals(1)
        let late = Task { await model.scan() }
        await gates.waitForArrivals(2)
        gates.open(0)
        await first.value
        guard case .ready = model.state else { Issue.record("not ready: \(model.state)"); return }
        model.selection = PasteSelection(history: true, boards: [])
        model.start()
        gates.open(1)
        await late.value
        if case .ready = model.state { Issue.record("a late scan made a running import ready again") }
        #expect(model.selection == PasteSelection(history: true, boards: []))
        await model.finished()
        guard case .done(let report) = model.state else { Issue.record("not done: \(model.state)"); return }
        #expect(report.added == 2)
    }

    @Test func aSecondStartWhileImportingDoesNothing() async throws {
        let counter = Counter()
        let model = try makeModel(location: try syntheticLocation(), counter: counter)
        await model.scan()
        guard case .ready(let summary, let location) = model.state else { Issue.record("not ready: \(model.state)"); return }
        model.start()
        // Ready again while the first import runs, as a stray scan could once leave it.
        model.state = .ready(summary, location)
        model.start()
        #expect(model.state == .ready(summary, location))
        await model.finished()
        #expect(counter.reloads == 1)
    }

    /// The other app held its library: once it has quit, the library is read again.
    @Test func quittingTheOtherAppAfterAFailureScansAgain() async throws {
        let folder = TestScratch.url("imp-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let counter = Counter()
        let model = try makeModel(location: PasteLibraryLocation(folder: folder, vendor: nil), counter: counter)
        await model.scan()
        #expect(model.state == .failed)
        try SyntheticPasteLibrary.make(in: folder, items: [
            .init(externalID: "h1", createdAt: 100, timestamp: 110, payload: .plain([[("public.utf8-plain-text", "one")]])),
        ])
        model.quitOtherApp()
        // Awaited, not polled: parallel suites can keep the main actor busy for seconds.
        await model.quitWatch?.value
        #expect(isReady(model.state))
        #expect(counter.quits == 1)
    }

    /// A visit to Settings › Import while the library is ready keeps it as it is: no new scan, the choice stays.
    @Test func aVisitWhileReadyKeepsTheChoice() async throws {
        let model = try makeModel(location: try syntheticLocation())
        let reads = Reads()
        let read = model.summarize
        model.summarize = { location in
            reads.add()
            return await read(location)
        }
        await model.paneAppeared()
        guard case .ready(let summary, let location) = model.state else { Issue.record("not ready: \(model.state)"); return }
        #expect(reads.count == 1)
        model.selection = PasteSelection(history: false, boards: [7])
        await model.paneAppeared()
        #expect(reads.count == 1)
        #expect(model.state == .ready(summary, location))
        #expect(model.selection == PasteSelection(history: false, boards: [7]))
    }

    /// After a failure, a missing library or a finished import, the next visit reads the library again.
    @Test func aVisitAfterAnEndReadsAgain() async throws {
        let model = try makeModel(location: try syntheticLocation())
        let reads = Reads()
        let read = model.summarize
        model.summarize = { location in
            reads.add()
            return await read(location)
        }
        for ended in [ImportModel.State.failed, .unavailable, .done(ImportReport())] {
            model.state = ended
            let before = reads.count
            await model.paneAppeared()
            #expect(reads.count == before + 1)
            #expect(isReady(model.state))
        }
        model.state = .importing(ImportProgress(done: 1, total: 4, kinds: [:]))
        await model.paneAppeared()
        #expect(model.state == .importing(ImportProgress(done: 1, total: 4, kinds: [:])))
    }

    @Test func theCardKeepsItsLinesWhileImporting() async throws {
        let model = try makeModel(location: try syntheticLocation())
        await model.scan()
        let source = model.sourceLine, stats = model.statsLine
        #expect(!source.isEmpty && !stats.isEmpty)
        model.start()
        guard case .importing = model.state else { Issue.record("not importing: \(model.state)"); return }
        #expect(model.sourceLine == source)
        #expect(model.statsLine == stats)
        await model.finished()
    }

    @Test func aFailedOpenShowsFailed() async throws {
        let folder = TestScratch.url("imp-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = try makeModel(location: PasteLibraryLocation(folder: folder, vendor: nil))
        await model.scan()
        #expect(model.state == .failed)
    }
}

private func isReady(_ state: ImportModel.State) -> Bool {
    if case .ready = state { true } else { false }
}

/// Counts library reads.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Holds each caller of `pass()` until its gate (by order of arrival) is opened.
private final class Gates: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>?] = []
    private var opened: Set<Int> = []

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            let index = waiting.count
            let open = opened.contains(index)
            waiting.append(open ? nil : continuation)
            lock.unlock()
            if open { continuation.resume() }
        }
    }

    func waitForArrivals(_ count: Int) async {
        while lock.withLock({ waiting.count }) < count { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func open(_ index: Int) {
        lock.lock()
        opened.insert(index)
        let continuation = index < waiting.count ? waiting[index] : nil
        if index < waiting.count { waiting[index] = nil }
        lock.unlock()
        continuation?.resume()
    }
}
