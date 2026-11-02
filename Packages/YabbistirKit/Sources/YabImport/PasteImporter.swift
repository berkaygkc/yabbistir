import Foundation
import YabCore
import YabPasteboard

/// What the person chose to bring over: the history, and any of the pinboards.
public struct PasteSelection: Sendable, Equatable {
    public var history: Bool
    public var boards: Set<Int64>

    public init(history: Bool, boards: Set<Int64>) {
        self.history = history
        self.boards = boards
    }
}

public struct ImportProgress: Sendable, Equatable {
    public var done: Int
    public let total: Int
    public var kinds: [ItemKind: Int]

    public init(done: Int, total: Int, kinds: [ItemKind: Int]) {
        self.done = done
        self.total = total
        self.kinds = kinds
    }
}

public struct ImportReport: Sendable, Equatable {
    public var added = 0
    public var merged = 0
    /// Imported before, from an ignored app, or marked private.
    public var skipped = 0
    public var failed = 0
    public var kinds: [ItemKind: Int] = [:]
    public var categoriesCreated = 0

    public init() {}
}

/// Brings another clipboard manager's history and pinboards over, once, without aging anything.
/// Blocking: call it off the main actor, then reload the history index once.
public struct PasteImporter: Sendable {
    /// The `source` every imported item is recorded under.
    public static let source = "paste"

    /// How often progress is reported: every `step` items or `interval` of wall time, whichever comes first.
    struct Throttle: Sendable {
        var step = 50
        var interval: Duration = .milliseconds(100)
    }

    private let store: ItemStore
    private let filter: CaptureFilter
    private let now: Date
    private let throttle: Throttle
    /// Test seam: runs before each item is brought; what it throws stops the run, as a quit or an unreadable page would.
    private let beforeItem: (@Sendable (PasteItem) throws -> Void)?

    public init(store: ItemStore, ignoredApps: Set<String>, now: Date) {
        self.init(store: store, ignoredApps: ignoredApps, now: now, throttle: Throttle(), beforeItem: nil)
    }

    init(store: ItemStore, ignoredApps: Set<String>, now: Date, throttle: Throttle,
         beforeItem: (@Sendable (PasteItem) throws -> Void)? = nil) {
        self.throttle = throttle
        self.beforeItem = beforeItem
        self.store = store
        var filter = CaptureFilter()
        filter.ignoredBundleIDs = ignoredApps
        self.filter = filter
        self.now = now
    }

    public func run(_ library: PasteLibrary, selection: PasteSelection,
                    progress: @Sendable (ImportProgress) -> Void) throws -> ImportReport {
        let summary = try library.summary()
        let chosen = summary.boards.filter { selection.boards.contains($0.id) }
        let total = (selection.history ? summary.historyCount : 0) + chosen.reduce(0) { $0 + $1.count }

        var report = ImportReport()
        var done = 0
        var reported = -1
        let clock = ContinuousClock()
        var lastReport = clock.now
        // Every chosen pinboard has its category before the first item comes in, so an item is filed in the same
        // transaction that imports it: a run that stops partway leaves nothing for a later run to file.
        let (filings, created) = try categories(for: chosen)

        func notify() {
            reported = done
            lastReport = clock.now
            progress(ImportProgress(done: done, total: total, kinds: report.kinds))
        }

        try library.items(history: selection.history, boards: selection.boards) { batch in
            for item in batch {
                try beforeItem?(item)
                let outcome: Brought
                if let board = item.boardID, filings[board] == nil {
                    // Its category could not be made: it stays out, and a later run brings it.
                    outcome = .failed
                } else {
                    do { outcome = try bring(item, filing: item.boardID.flatMap { filings[$0] }) } catch { outcome = .failed }
                }
                switch outcome {
                case .added(let kind):
                    report.added += 1
                    report.kinds[kind, default: 0] += 1
                case .merged: report.merged += 1
                case .skipped: report.skipped += 1
                case .failed: report.failed += 1
                }
                done += 1
                if done - reported >= throttle.step || clock.now - lastReport >= throttle.interval { notify() }
            }
        }

        report.categoriesCreated = keepFilled(created)
        if reported != done { notify() }
        return report
    }

    private enum Brought {
        case added(ItemKind), merged, skipped, failed
    }

    private func bring(_ item: PasteItem, filing: ImportFiling?) throws -> Brought {
        var items: [[PasteboardRepresentation]]
        switch item.payload {
        case .success(let decoded):
            items = decoded
        case .failure:
            // Nothing decodable survives, but a title still says what the item was.
            guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return .failed }
            items = [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(title.utf8))]]
        }
        let types = Set(items.flatMap { $0.map(\.type) })
        if case .skip = filter.evaluate(types: types, source: item.source) { return .skipped }

        let clip = ImportedClip(items: items, source: item.source, device: .local, firstCopiedAt: item.firstCopiedAt,
                                lastCopiedAt: item.lastCopiedAt, externalID: item.externalID)
        switch try store.importClip(clip, from: Self.source, usedAt: now, filing: filing) {
        case .added: return .added(ItemClassifier.classify(items)?.kind ?? .text)
        case .merged: return .merged
        case .alreadyImported: return .skipped
        case .nothingToKeep: return .failed
        }
    }

    /// Each chosen pinboard joins the same-named category of the person's own (never an extension's source
    /// category), or gets a new one. Pinned-only items stay out of History. A board whose category cannot be made
    /// has no filing; the other boards carry on. Returns the filings by board and the categories made.
    private func categories(for boards: [PasteBoard]) throws -> (filings: [Int64: ImportFiling], created: [Int64]) {
        var categories = try store.categories()
        var filings: [Int64: ImportFiling] = [:]
        var created: [Int64] = []
        for board in boards.sorted(by: { $0.id < $1.id }) {
            let trimmed = board.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Pinboard \(board.id)" : trimmed
            let folded = SearchNormalizer.normalize(name)
            if let found = categories.first(where: { !$0.isSource && SearchNormalizer.normalize($0.name) == folded }), let id = found.id {
                filings[board.id] = ImportFiling(categoryID: id, hidesNewItem: true)
                continue
            }
            guard let category = try? store.createCategory(name: name, color: store.nextCategoryColor(), visibility: .onSelect),
                  let id = category.id else { continue }
            categories.append(category)
            created.append(id)
            filings[board.id] = ImportFiling(categoryID: id, hidesNewItem: true)
        }
        return (filings, created)
    }

    /// A category made for a pinboard whose items all stayed out (imported before, ignored, failed) is removed again,
    /// so a run never leaves an empty column. Returns how many made ones stay.
    private func keepFilled(_ created: [Int64]) -> Int {
        var kept = 0
        for id in created {
            if (try? store.itemIDs(inCategory: id))?.isEmpty == true {
                _ = try? store.deleteCategory(id: id)
            } else {
                kept += 1
            }
        }
        return kept
    }
}
