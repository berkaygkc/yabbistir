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
    /// Test seam: runs before a pinboard item is added to its category and may throw.
    private let beforeFiling: (@Sendable (Int64) throws -> Void)?

    public init(store: ItemStore, ignoredApps: Set<String>, now: Date) {
        self.init(store: store, ignoredApps: ignoredApps, now: now, throttle: Throttle(), beforeFiling: nil)
    }

    init(store: ItemStore, ignoredApps: Set<String>, now: Date, throttle: Throttle,
         beforeFiling: (@Sendable (Int64) throws -> Void)? = nil) {
        self.throttle = throttle
        self.beforeFiling = beforeFiling
        self.store = store
        var filter = CaptureFilter()
        filter.ignoredBundleIDs = ignoredApps
        self.filter = filter
        self.now = now
    }

    public func run(_ library: PasteLibrary, selection: PasteSelection,
                    progress: @Sendable (ImportProgress) -> Void) throws -> ImportReport {
        let summary = try library.summary()
        let names = Dictionary(uniqueKeysWithValues: summary.boards.map { ($0.id, $0.name) })
        let total = (selection.history ? summary.historyCount : 0)
            + summary.boards.filter { selection.boards.contains($0.id) }.reduce(0) { $0 + $1.count }

        var report = ImportReport()
        var done = 0
        var reported = -1
        let clock = ContinuousClock()
        var lastReport = clock.now
        // Items per pinboard, in the pinboard's display order. New board-only items are hidden from history
        // only once they are in their category.
        var members: [Int64: [Member]] = [:]

        func notify() {
            reported = done
            lastReport = clock.now
            progress(ImportProgress(done: done, total: total, kinds: report.kinds))
        }

        try library.items(history: selection.history, boards: selection.boards) { batch in
            for item in batch {
                let outcome: Brought
                do { outcome = try bring(item) } catch { outcome = .failed }
                switch outcome {
                case .added(let id, let kind):
                    report.added += 1
                    report.kinds[kind, default: 0] += 1
                    if let board = item.boardID { members[board, default: []].append(Member(id: id, isNew: true, kind: kind)) }
                case .merged(let id):
                    report.merged += 1
                    if let board = item.boardID { members[board, default: []].append(Member(id: id, isNew: false, kind: nil)) }
                case .skipped: report.skipped += 1
                case .failed: report.failed += 1
                }
                done += 1
                if done - reported >= throttle.step || clock.now - lastReport >= throttle.interval { notify() }
            }
        }

        try file(members, names: names, into: &report)
        if reported != done { notify() }
        return report
    }

    private enum Brought {
        case added(Int64, ItemKind), merged(Int64), skipped, failed
    }

    private func bring(_ item: PasteItem) throws -> Brought {
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
        switch try store.importClip(clip, from: Self.source, usedAt: now) {
        case .added(let id):
            guard let kind = ItemClassifier.classify(items)?.kind else { return .added(id, .text) }
            return .added(id, kind)
        case .merged(let id): return .merged(id)
        case .alreadyImported: return .skipped
        case .nothingToKeep: return .failed
        }
    }

    private struct Member {
        let id: Int64
        let isNew: Bool
        let kind: ItemKind?
    }

    /// Each pinboard becomes (or joins) a category. A category lists its last-added item first, so items go in
    /// reverse: the pinboard's top item ends on top. A board that cannot be filed leaves its items in history
    /// and counts them as failed; the other boards carry on.
    private func file(_ members: [Int64: [Member]], names: [Int64: String], into report: inout ImportReport) throws {
        var categories = try store.categories()
        for board in members.keys.sorted() {
            guard let items = members[board], !items.isEmpty else { continue }
            let trimmed = (names[board] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Pinboard \(board)" : trimmed
            let folded = SearchNormalizer.normalize(name)
            var filed = 0
            do {
                let category: ClipCategory
                if let found = categories.first(where: { !$0.isSource && SearchNormalizer.normalize($0.name) == folded }) {
                    category = found
                } else {
                    category = try store.createCategory(name: name, color: try store.nextCategoryColor(), visibility: .onSelect)
                    categories.append(category)
                    report.categoriesCreated += 1
                }
                for member in items.reversed() {
                    try beforeFiling?(member.id)
                    try store.add(itemID: member.id, toCategory: category.id!)
                    if member.isNew { try store.hideFromHistory(member.id) }
                    filed += 1
                }
            } catch {
                for member in items.reversed().dropFirst(filed) {
                    if member.isNew, let kind = member.kind {
                        report.added -= 1
                        report.kinds[kind, default: 1] -= 1
                        if report.kinds[kind] == 0 { report.kinds[kind] = nil }
                    } else if !member.isNew {
                        report.merged -= 1
                    }
                    report.failed += 1
                }
            }
        }
    }
}
