import CryptoKit
import Foundation
import GRDB

public struct ClipItem: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "item"
    public var id: Int64?
    public var kind: ItemKind
    public var previewText: String
    public var searchText: String
    public var contentHash: String
    public var sourceBundleID: String?
    public var sourceName: String?
    public var device: DeviceKind
    public var firstCopiedAt: Date
    public var lastCopiedAt: Date
    public var lastUsedAt: Date
    /// False for an item removed from history but kept in a category.
    public var inHistory: Bool = true

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// What a history row shows. Leaves out the search text, which runs to 20,000 characters.
public struct ClipSummary: Decodable, Sendable, Equatable, FetchableRecord {
    public var id: Int64
    public var kind: ItemKind
    public var previewText: String
    /// For links: the URL at the head of the search text.
    public var linkURL: String?
    public var device: DeviceKind
    public var lastCopiedAt: Date
    /// The app it was copied from (the Sıra shows it under each item).
    public var sourceName: String?
}

public struct IngestResult: Sendable {
    public var item: ClipItem
    public var isNew: Bool
}

/// Persists clips (SQLite via GRDB) and their full-fidelity representations.
public final class ItemStore: Sendable {
    public static let inlineLimit = 64 * 1024

    let dbPool: DatabasePool
    let blobs: BlobStore

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        blobs = BlobStore(directory: directory.appendingPathComponent("Blobs", isDirectory: true))
        dbPool = try DatabasePool(path: directory.appendingPathComponent("db.sqlite").path)
        let migrator = Schema.migrator(blobs: blobs)
        // Asked on the writer: a reader opened before a schema migration keeps a stale column cache.
        let mergesDuplicates = try dbPool.writeWithoutTransaction { db in
            try !migrator.appliedIdentifiers(db).contains(Schema.contentIdentityMigration)
        }
        try migrator.migrate(dbPool)
        if mergesDuplicates { try removeUnreferencedBlobFiles() }
    }

    /// Gives the space of deleted rows back to the disk: items under `inlineLimit` live inside the database file,
    /// which only shrinks when it is rebuilt.
    public func compact() throws {
        try dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try db.checkpoint(.truncate)
        }
    }

    public static func temporary() throws -> ItemStore {
        try ItemStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("yabbistir-tests-\(UUID().uuidString)", isDirectory: true))
    }

    /// Inserts a new clip, or bumps the item that already holds the same content. The latest
    /// copy wins: its representations, preview and source replace the stored ones.
    /// Returns nil when the clip has nothing worth keeping.
    public func ingest(_ clip: CapturedClip) throws -> IngestResult? {
        guard let classification = ItemClassifier.classify(clip.items) else { return nil }
        // Hash each payload once: the hashes name the blobs and define the item's identity.
        let hashes = clip.items.map { $0.map { BlobStore.hash($0.data) } }
        let identity = Self.identityHash(clip.items, kind: classification.kind, hashes: hashes)

        var stored: [(record: StoredRepresentation, data: Data)] = []
        for (itemIndex, item) in clip.items.enumerated() {
            for (position, rep) in item.enumerated() {
                let blobHash = rep.data.count > Self.inlineLimit ? hashes[itemIndex][position] : nil
                if let blobHash { try blobs.write(rep.data, hash: blobHash) }
                stored.append((StoredRepresentation(
                    id: nil, itemID: 0, itemIndex: itemIndex, position: position, type: rep.type,
                    inlineData: blobHash == nil ? rep.data : nil, blobHash: blobHash, byteCount: rep.data.count), rep.data))
            }
        }

        return try dbPool.write { db in
            var item = ClipItem(
                id: nil, kind: classification.kind, previewText: classification.previewText,
                searchText: classification.searchText, contentHash: identity,
                sourceBundleID: clip.source?.bundleID, sourceName: clip.source?.name, device: clip.device,
                firstCopiedAt: clip.capturedAt, lastCopiedAt: clip.capturedAt, lastUsedAt: clip.capturedAt)
            var released: [String] = []
            let existing = try ClipItem.filter(Column("contentHash") == identity).fetchOne(db)
            if let existing, let id = existing.id {
                item.id = id
                item.firstCopiedAt = existing.firstCopiedAt
                try item.update(db)
                released = try String.fetchAll(db, sql: "SELECT blobHash FROM representation WHERE itemID = ? AND blobHash IS NOT NULL",
                                               arguments: [id])
                try StoredRepresentation.filter(Column("itemID") == id).deleteAll(db)
            } else {
                try item.insert(db)
            }
            for (var record, data) in stored {
                record.itemID = item.id!
                try record.insert(db)
                // A purge may have removed a shared blob since it was written above.
                if let blobHash = record.blobHash { try blobs.write(data, hash: blobHash) }
            }
            try removeUnreferencedBlobs(released, db)
            return IngestResult(item: item, isNew: existing == nil)
        }
    }

    public func representations(of itemID: Int64) throws -> [[PasteboardRepresentation]] {
        let rows = try dbPool.read { db in
            try StoredRepresentation
                .filter(Column("itemID") == itemID)
                .order(Column("itemIndex"), Column("position"))
                .fetchAll(db)
        }
        var items: [[PasteboardRepresentation]] = []
        for row in rows {
            let data = try row.inlineData ?? blobs.read(row.blobHash ?? "")
            while items.count <= row.itemIndex { items.append([]) }
            items[row.itemIndex].append(PasteboardRepresentation(type: row.type, data: data))
        }
        return items
    }

    /// Only the representations of the given types (no other payload is read from disk).
    public func representations(of itemID: Int64, types: Set<String>) throws -> [[PasteboardRepresentation]] {
        guard !types.isEmpty else { return [] }
        let rows = try dbPool.read { db in
            try StoredRepresentation
                .filter(Column("itemID") == itemID && types.contains(Column("type")))
                .order(Column("itemIndex"), Column("position"))
                .fetchAll(db)
        }
        var items: [[PasteboardRepresentation]] = []
        for row in rows {
            let data = try row.inlineData ?? blobs.read(row.blobHash ?? "")
            while items.count <= row.itemIndex { items.append([]) }
            items[row.itemIndex].append(PasteboardRepresentation(type: row.type, data: data))
        }
        return items
    }

    /// True when the item has a representation of any of these types; reads type names only, never payloads.
    public func hasRepresentation(itemID: Int64, ofTypes types: Set<String>) throws -> Bool {
        guard !types.isEmpty else { return false }
        return try dbPool.read { db in
            try StoredRepresentation.filter(Column("itemID") == itemID && types.contains(Column("type"))).fetchCount(db) > 0
        }
    }

    /// Every file URL a stored item points at (result files live as long as one does).
    public func referencedFileURLs() throws -> Set<String> {
        let rows = try dbPool.read { db in
            try StoredRepresentation.filter(Column("type") == TypeIdentifiers.fileURL).fetchAll(db)
        }
        return Set(try rows.map { row in String(decoding: try row.inlineData ?? blobs.read(row.blobHash ?? ""), as: UTF8.self) })
    }

    /// Every item that has a file URL representation: its id, the URL string and when it was last
    /// copied (the result files' size limit walks these from the oldest).
    public func resultFileItems() throws -> [(itemID: Int64, url: String, date: Date)] {
        let rows = try dbPool.read { db in
            try StoredRepresentation.filter(Column("type") == TypeIdentifiers.fileURL).fetchAll(db)
        }
        return try rows.compactMap { row in
            guard let item = try dbPool.read({ db in try ClipItem.fetchOne(db, key: row.itemID) }) else { return nil }
            return (row.itemID, String(decoding: try row.inlineData ?? blobs.read(row.blobHash ?? ""), as: UTF8.self), item.lastCopiedAt)
        }
    }

    public func history(limit: Int) throws -> [ClipItem] {
        try dbPool.read { db in
            try ClipItem.order(Column("lastCopiedAt").desc, Column("id").desc).limit(limit).fetchAll(db)
        }
    }

    public func item(id: Int64) throws -> ClipItem? {
        try dbPool.read { db in try ClipItem.fetchOne(db, key: id) }
    }

    /// Fetches row summaries in the order of `ids` (search results arrive pre-ranked).
    public func summaries(ids: [Int64]) throws -> [ClipSummary] {
        guard !ids.isEmpty else { return [] }
        let fetched = try dbPool.read { db in
            try ClipSummary.fetchAll(db, sql: """
                SELECT id, kind, previewText, device, lastCopiedAt, sourceName,
                       CASE kind WHEN 'link' THEN substr(searchText, 1, instr(searchText || ' ', ' ') - 1) END AS linkURL
                FROM item WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids))
        }
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    public func delete(_ itemID: Int64) throws {
        try delete([itemID])
    }

    /// Deletes items and garbage-collects blobs no longer referenced by any representation.
    func delete(_ itemIDs: [Int64]) throws {
        guard !itemIDs.isEmpty else { return }
        try dbPool.write { db in try deleteItems(itemIDs, db) }
    }

    func deleteItems(_ itemIDs: [Int64], _ db: Database) throws {
        guard !itemIDs.isEmpty else { return }
        let hashes = try String.fetchAll(db, sql: """
            SELECT DISTINCT blobHash FROM representation
            WHERE blobHash IS NOT NULL AND itemID IN (\(itemIDs.map { _ in "?" }.joined(separator: ",")))
            """, arguments: StatementArguments(itemIDs))
        _ = try ClipItem.deleteAll(db, keys: itemIDs)
        try removeUnreferencedBlobs(hashes, db)
    }

    /// Removes the files of blobs no representation references any more. Runs inside the write
    /// transaction, so an ingest cannot re-reference a file between the check and the removal.
    private func removeUnreferencedBlobs(_ hashes: [String], _ db: Database) throws {
        for hash in Set(hashes)
        where try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM representation WHERE blobHash = ?", arguments: [hash]) == 0 {
            try blobs.remove(hash)
        }
    }

    /// Deletes blob files that no representation points to (left behind by the v2 merge).
    func removeUnreferencedBlobFiles() throws {
        try dbPool.write { db in
            let referenced = Set(try String.fetchAll(db, sql: "SELECT DISTINCT blobHash FROM representation WHERE blobHash IS NOT NULL"))
            for hash in try blobs.allHashes() where !referenced.contains(hash) {
                try blobs.remove(hash)
            }
        }
    }

    /// Identity of an item: its kind plus the hashes of the representations that carry the content.
    static func identityHash(_ items: [[PasteboardRepresentation]], kind: ItemKind, hashes: [[String]]) -> String {
        var positions = ItemClassifier.identityPositions(of: items, kind: kind)
        if positions.isEmpty {
            positions = items.indices.flatMap { index in items[index].indices.map { (index, $0) } }
        }
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        for (item, position) in positions {
            hasher.update(data: Data("|\(items[item][position].type)|\(hashes[item][position])".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
