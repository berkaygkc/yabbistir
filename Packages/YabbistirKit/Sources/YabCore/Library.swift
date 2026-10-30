import Foundation

/// The library the app works on: the store plus its in-memory search index. Every change goes
/// through here so the index never drifts from the database, and `onChange` lets open views refresh.
@MainActor
public final class Library {
    public let store: ItemStore
    public private(set) var index: HistoryIndex
    public var onChange: (() -> Void)?
    /// Read-through caches for the panel's per-keystroke rebuild; cleared on every change.
    private var memberships: [Int64: [Int64]] = [:]
    private var summaryCache: [Int64: ClipSummary] = [:]

    public init(store: ItemStore) throws {
        self.store = store
        index = HistoryIndex(items: try store.history(limit: 200_000))
    }

    public func didIngest(_ item: ClipItem) {
        index.upsert(item)
        changed()
    }

    /// A paste or copy from the panel: renews retention and brings the item to the top of history.
    public func markUsed(_ id: Int64, at date: Date) throws {
        try store.markUsed(id, at: date)
        try refresh([id])
    }

    /// True when the item was deleted (it was in no category), not only taken out of history.
    @discardableResult
    public func deleteFromHistory(_ id: Int64) throws -> Bool {
        let deleted = try store.deleteFromHistory(id)
        try refresh([id])
        return deleted
    }

    /// True when that deleted the item (it was in nothing else).
    @discardableResult
    public func remove(_ id: Int64, fromCategory categoryID: Int64) throws -> Bool {
        let deleted = try store.remove(itemID: id, fromCategory: categoryID)
        try refresh([id])
        return deleted
    }

    /// ⌘P on a category row: adds the item, or takes it out when it is already there.
    public func toggle(_ id: Int64, inCategory categoryID: Int64) throws {
        if try store.categoryIDs(ofItem: id).contains(categoryID) {
            try remove(id, fromCategory: categoryID)
        } else {
            try add(id, toCategory: categoryID)
        }
    }

    /// Puts the item in the category (already there: nothing changes).
    public func add(_ id: Int64, toCategory categoryID: Int64) throws {
        try store.add(itemID: id, toCategory: categoryID)
        changed()
    }

    public func createCategory(name: String) throws -> ClipCategory {
        let category = try store.createCategory(name: name, color: try store.nextCategoryColor())
        changed()
        return category
    }

    public func updateCategory(_ category: ClipCategory) throws {
        try store.updateCategory(category)
        changed()
    }

    public func moveCategory(id: Int64, to index: Int) throws {
        try store.moveCategory(id: id, to: index)
        changed()
    }

    public func deleteCategory(id: Int64) throws {
        for deleted in try store.deleteCategory(id: id) { index.remove(id: deleted) }
        changed()
    }

    public func purgeExpired(policy: RetentionPolicy, now: Date) throws {
        let removed = try store.purgeExpired(policy: policy, now: now)
        guard !removed.isEmpty else { return }
        for id in removed { index.remove(id: id) }
        changed()
    }

    /// A category's items, most recently added first (cached).
    public func itemIDs(inCategory categoryID: Int64) -> [Int64] {
        if let cached = memberships[categoryID] { return cached }
        let ids = (try? store.itemIDs(inCategory: categoryID)) ?? []
        memberships[categoryID] = ids
        return ids
    }

    /// Row summaries in the order of `ids` (cached).
    public func summaries(ids: [Int64]) -> [ClipSummary] {
        let missing = ids.filter { summaryCache[$0] == nil }
        if !missing.isEmpty {
            for summary in (try? store.summaries(ids: missing)) ?? [] { summaryCache[summary.id] = summary }
        }
        return ids.compactMap { summaryCache[$0] }
    }

    /// Detectors re-tagged these items: open views redraw their rows.
    public func tagsChanged(_ ids: [Int64]) {
        changed()
    }

    private func changed() {
        memberships = [:]
        summaryCache = [:]
        onChange?()
    }

    /// Re-reads items after a change: deleted ones leave the index, the rest are re-placed.
    private func refresh(_ ids: [Int64]) throws {
        for id in ids {
            if let item = try store.item(id: id) { index.upsert(item) } else { index.remove(id: id) }
        }
        changed()
    }
}
