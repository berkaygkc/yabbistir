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

    private static let progressEvery = 50
    private static let progressInterval: Duration = .milliseconds(100)

    private let store: ItemStore
    private let filter: CaptureFilter
    private let now: Date

    public init(store: ItemStore, ignoredApps: Set<String>, now: Date) {
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
        // Item ids per pinboard, in the pinboard's display order.
        var members: [Int64: [Int64]] = [:]

        func notify() {
            reported = done
            lastReport = clock.now
            progress(ImportProgress(done: done, total: total, kinds: report.kinds))
        }

        try library.items(history: selection.history, boards: selection.boards) { batch in
            for item in batch {
                let outcome = try bring(item)
                switch outcome {
                case .added(let id, let kind):
                    report.added += 1
                    report.kinds[kind, default: 0] += 1
                    if let board = item.boardID {
                        try store.hideFromHistory(id)
                        members[board, default: []].append(id)
                    }
                case .merged(let id):
                    report.merged += 1
                    if let board = item.boardID { members[board, default: []].append(id) }
                case .skipped: report.skipped += 1
                case .failed: report.failed += 1
                }
                done += 1
                if done - reported >= Self.progressEvery || clock.now - lastReport >= Self.progressInterval { notify() }
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

    /// Each pinboard becomes (or joins) a category. A category lists its last-added item first, so items go in
    /// reverse: the pinboard's top item ends on top.
    private func file(_ members: [Int64: [Int64]], names: [Int64: String], into report: inout ImportReport) throws {
        var categories = try store.categories()
        for board in members.keys.sorted() {
            guard let ids = members[board], !ids.isEmpty else { continue }
            let name = names[board] ?? "Pinboard \(board)"
            let folded = SearchNormalizer.normalize(name.trimmingCharacters(in: .whitespacesAndNewlines))
            let category: ClipCategory
            if let found = categories.first(where: { !$0.isSource && SearchNormalizer.normalize($0.name) == folded }) {
                category = found
            } else {
                category = try store.createCategory(name: name, color: try store.nextCategoryColor(), visibility: .onSelect)
                categories.append(category)
                report.categoriesCreated += 1
            }
            for id in ids.reversed() { try store.add(itemID: id, toCategory: category.id!) }
        }
    }
}
