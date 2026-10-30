import Darwin
import Foundation

public struct SearchResult: Sendable, Equatable {
    public var ids: [Int64]
    public var total: Int
}

/// In-memory, newest-first search over normalized item text. A linear byte scan
/// (memmem) is fast enough for tens of thousands of items and stays predictable.
public struct HistoryIndex: Sendable {
    public struct Entry: Sendable, Equatable {
        public var id: Int64
        public var kind: ItemKind
        public var searchText: String
        public var isRemote: Bool
        public var lastCopiedAt: Date
        public var inHistory: Bool
    }

    /// Type names users can type to filter by kind (normalized, prefix-matched, ≥2 chars).
    static let typeWords: [ItemKind: [String]] = [
        .link: ["link", "baglanti"], .image: ["image", "gorsel", "resim"],
        .color: ["color", "colour", "renk"], .file: ["file", "dosya"],
        .code: ["code", "kod"], .text: ["text", "metin"],
    ]
    static let remoteWords = ["iphone"]

    private var entries: [Entry] = []
    private var bytes: [[UInt8]] = []
    /// Item id → position, so a category's search visits only its members.
    private var positions: [Int64: Int] = [:]

    public init(items: [ClipItem]) {
        for item in items.sorted(by: { $0.lastCopiedAt > $1.lastCopiedAt }) {
            guard let entry = Self.entry(for: item) else { continue }
            entries.append(entry)
            bytes.append(Array(entry.searchText.utf8))
        }
        reindex()
    }

    private mutating func reindex() {
        positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
    }

    public var count: Int { entries.count }

    /// Inserts or moves an item to its recency position (new captures and bumps go to the front).
    public mutating func upsert(_ item: ClipItem) {
        guard let entry = Self.entry(for: item) else { return }
        remove(id: entry.id)
        let position = entries.firstIndex { $0.lastCopiedAt <= entry.lastCopiedAt } ?? entries.endIndex
        entries.insert(entry, at: position)
        bytes.insert(Array(entry.searchText.utf8), at: position)
        reindex()
    }

    public mutating func remove(id: Int64) {
        guard let position = positions[id] else { return }
        entries.remove(at: position)
        bytes.remove(at: position)
        reindex()
    }

    /// History-column search: items still in history, newest first. `total` counts every match,
    /// not just the first `limit`.
    public func search(_ query: String, limit: Int) -> SearchResult {
        let matcher = Matcher(query)
        var result = SearchResult(ids: [], total: 0)
        for (position, entry) in entries.enumerated() where entry.inHistory && matcher.matches(entry, bytes[position]) {
            result.total += 1
            if result.ids.count < limit { result.ids.append(entry.id) }
        }
        return result
    }

    /// Category-column search: keeps the order of `ids` and ignores whether an item is in history.
    public func filter(_ ids: [Int64], query: String) -> [Int64] {
        let matcher = Matcher(query)
        guard !matcher.isEmpty else { return ids }
        return ids.filter { id in positions[id].map { matcher.matches(entries[$0], bytes[$0]) } ?? false }
    }

    /// A normalized query plus the item kinds and device it names ("görsel", "iphone").
    private struct Matcher {
        let needle: [UInt8]
        let kinds: Set<ItemKind>
        let matchesRemote: Bool
        var isEmpty: Bool { needle.isEmpty }

        init(_ query: String) {
            let normalized = SearchNormalizer.normalize(query.trimmingCharacters(in: .whitespaces))
            needle = Array(normalized.utf8)
            kinds = normalized.count >= 2
                ? Set(HistoryIndex.typeWords.filter { $0.value.contains { $0.hasPrefix(normalized) } }.keys) : []
            matchesRemote = normalized.count >= 2 && HistoryIndex.remoteWords.contains { $0.hasPrefix(normalized) }
        }

        func matches(_ entry: Entry, _ haystack: [UInt8]) -> Bool {
            needle.isEmpty || kinds.contains(entry.kind) || (matchesRemote && entry.isRemote)
                || HistoryIndex.contains(haystack, needle)
        }
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
            }
        }
    }

    private static func entry(for item: ClipItem) -> Entry? {
        guard let id = item.id else { return nil }
        return Entry(id: id, kind: item.kind, searchText: item.searchText,
                     isRemote: item.device == .remote, lastCopiedAt: item.lastCopiedAt, inHistory: item.inHistory)
    }
}
