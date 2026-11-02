import Foundation
import Observation
import YabCore
import YabImport
import YabLocalization
import YabPlatform

/// Brings another clipboard manager's library over: finds it, summarizes it, runs the import off the main actor
/// and reports progress. Shared by Settings and the first-run window.
@MainActor @Observable
public final class ImportModel {
    public enum State: Equatable {
        case scanning, unavailable
        case ready(PasteSummary, PasteLibraryLocation)
        case importing(ImportProgress)
        case done(ImportReport)
        case failed
    }

    public internal(set) var state: State = .scanning
    /// What to bring over; everything to begin with.
    public var selection = PasteSelection(history: true, boards: [])
    public private(set) var otherAppRunning: Bool

    @ObservationIgnored private let store: ItemStore
    @ObservationIgnored private let reload: @MainActor () -> Void
    @ObservationIgnored private let ignoredApps: @MainActor () -> Set<String>
    @ObservationIgnored private let locate: () -> PasteLibraryLocation?
    @ObservationIgnored private let isOtherAppRunning: () -> Bool
    @ObservationIgnored private let quitOther: () -> Void
    @ObservationIgnored let language: LanguageStore
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Waits for the other app to quit, then reads its library again.
    @ObservationIgnored private(set) var quitWatch: Task<Void, Never>?
    /// The library being imported, so the card keeps its lines meanwhile.
    @ObservationIgnored private var importing: (summary: PasteSummary, location: PasteLibraryLocation)?
    /// Reads a library's summary from a copy, off the main actor (tests hold a scan back with it).
    @ObservationIgnored var summarize: @Sendable (PasteLibraryLocation) async -> PasteSummary? = { location in
        await Task.detached(priority: .userInitiated) { () -> PasteSummary? in
            guard let library = try? PasteLibrary.open(location) else { return nil }
            defer { library.close() }
            return try? library.summary()
        }.value
    }

    public init(store: ItemStore, reload: @escaping @MainActor () -> Void, ignoredApps: @escaping @MainActor () -> Set<String>,
                locate: @escaping () -> PasteLibraryLocation? = { PasteLibrary.find() },
                otherAppRunning: @escaping () -> Bool = OtherClipboardApp.isRunning,
                quitOtherApp: @escaping () -> Void = OtherClipboardApp.quit, language: LanguageStore) {
        self.store = store
        self.reload = reload
        self.ignoredApps = ignoredApps
        self.locate = locate
        self.isOtherAppRunning = otherAppRunning
        self.quitOther = quitOtherApp
        self.language = language
        self.otherAppRunning = otherAppRunning()
    }

    // MARK: Scanning

    /// Looks for the library and summarizes it (a copy is made off the main actor); selects everything. Does nothing
    /// while an import runs.
    public func scan() async {
        if case .importing = state { return }
        state = .scanning
        refreshOtherApp()
        guard let location = locate() else {
            state = .unavailable
            return
        }
        let summary = await summarize(location)
        // Another scan answered first and an import may have started since: this answer is stale.
        guard case .scanning = state else { return }
        guard let summary else {
            state = .failed
            return
        }
        selection = PasteSelection(history: true, boards: Set(summary.boards.map(\.id)))
        state = .ready(summary, location)
    }

    // MARK: Importing

    /// Runs the import in the background, then reloads the history index once, also after a failed run.
    public func start() {
        guard task == nil, case .ready(let summary, let location) = state else { return }
        importing = (summary, location)
        let selection = selection
        let total = (selection.history ? summary.historyCount : 0)
            + summary.boards.filter { selection.boards.contains($0.id) }.reduce(0) { $0 + $1.count }
        state = .importing(ImportProgress(done: 0, total: total, kinds: [:]))
        let importer = PasteImporter(store: store, ignoredApps: ignoredApps(), now: Date())
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) { [weak self] () -> ImportReport? in
                guard let library = try? PasteLibrary.open(location) else { return nil }
                defer { library.close() }
                return try? importer.run(library, selection: selection) { progress in
                    Task { @MainActor in self?.advance(to: progress) }
                }
            }.value
            state = outcome.map { .done($0) } ?? .failed
            importing = nil
            task = nil
            // A run that stopped partway has still written what it brought (each item filed with it).
            reload()
        }
    }

    /// Resolves when a running import has finished.
    public func finished() async {
        await task?.value
    }

    /// Progress hops arrive unordered with the end of the import, so they only ever move an import forward.
    private func advance(to progress: ImportProgress) {
        guard case .importing(let current) = state, progress.done >= current.done else { return }
        state = .importing(progress)
    }

    // MARK: The other app

    public func refreshOtherApp() {
        otherAppRunning = isOtherAppRunning()
    }

    /// Asks the other app to quit. It goes in its own time; once it has (within ten seconds), a library it kept from
    /// being read is read again.
    public func quitOtherApp() {
        quitOther()
        refreshOtherApp()
        quitWatch?.cancel()
        quitWatch = Task { [weak self] in
            for _ in 0..<100 {
                guard let self, !Task.isCancelled else { return }
                if !isOtherAppRunning() { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled, !isOtherAppRunning() else { return }
            refreshOtherApp()
            if case .failed = state { await scan() }
        }
    }

    // MARK: Text

    /// Pinned items in the chosen pinboards.
    public var selectedBoardItemCount: Int {
        guard case .ready(let summary, _) = state else { return 0 }
        return summary.boards.filter { selection.boards.contains($0.id) }.reduce(0) { $0 + $1.count }
    }

    /// The library the card shows: the one read, and while it is imported, that one.
    private var shownLibrary: (summary: PasteSummary, location: PasteLibraryLocation)? {
        switch state {
        case .ready(let summary, let location): (summary, location)
        case .importing: importing
        default: nil
        }
    }

    /// The sub-line under the name: the vendor (when there is one) and the folder holding the library.
    public var sourceLine: String {
        guard let location = shownLibrary?.location else { return "" }
        let folder = (location.folder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        guard let vendor = location.vendor else { return folder }
        return "\(vendor) · \(folder)"
    }

    public var sourceName: String { string("import.source.name") }

    /// "1,355 items · 130 MB".
    public var statsLine: String {
        guard shownLibrary != nil else { return "" }
        return string("import.source.stats", itemsPhrase(libraryItemCount), librarySize)
    }

    /// Every item in the library, history and pinboards together.
    public var libraryItemCount: Int {
        guard let summary = shownLibrary?.summary else { return 0 }
        return summary.historyCount + summary.boards.reduce(0) { $0 + $1.count }
    }

    /// What sits under the first-run card's large count: "items · 130 MB".
    public var unitLine: String {
        guard case .ready = state else { return "" }
        return libraryItemCount == 1 ? string("import.source.unit.one", librarySize) : string("import.source.unit", librarySize)
    }

    private var librarySize: String {
        guard let summary = shownLibrary?.summary else { return "" }
        return summary.totalBytes.formatted(.byteCount(style: .file).locale(language.language.locale))
    }

    /// "1 item", "1,355 items".
    public func itemsPhrase(_ count: Int) -> String {
        count == 1 ? string("import.items.one") : string("import.items", number(count))
    }

    public func historyCountText() -> String {
        guard case .ready(let summary, _) = state else { return "" }
        return number(summary.historyCount)
    }

    public func boardCountText(_ board: PasteBoard) -> String {
        number(board.count)
    }

    /// What the chosen pinboards become; empty when none is chosen.
    public var noteLine: String {
        guard case .ready(let summary, _) = state else { return "" }
        let chosen = summary.boards.filter { selection.boards.contains($0.id) }.count
        guard chosen > 0 else { return "" }
        let boards = chosen == 1 ? string("import.pinboards.one") : string("import.pinboards", number(chosen))
        let pinned = selectedBoardItemCount
        let items = pinned == 1 ? string("import.pinnedItems.one") : string("import.pinnedItems", number(pinned))
        return string("import.note", boards, items)
    }

    public var resultLine: String {
        guard case .done(let report) = state else { return "" }
        switch report.added {
        case 0: return string("import.result.none")
        case 1: return string("import.result.one")
        default: return string("import.result", number(report.added))
        }
    }

    /// Items that could not be brought over; nil when all came.
    public var failedLine: String? {
        guard case .done(let report) = state, report.failed > 0 else { return nil }
        return report.failed == 1 ? string("import.failed.one") : string("import.failed", number(report.failed))
    }

    public func number(_ value: Int) -> String {
        NumberFormatting.count(value, language: language.language)
    }

    private func string(_ key: String, _ arguments: CVarArg...) -> String {
        switch arguments.count {
        case 0: L10n.string(key, language.language)
        case 1: L10n.string(key, language.language, arguments[0])
        default: L10n.string(key, language.language, arguments[0], arguments[1])
        }
    }
}
