import Foundation
import GRDB

enum Schema {
    static func migrator(blobs: BlobStore) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("previewText", .text).notNull()
                t.column("searchText", .text).notNull()
                t.column("contentHash", .text).notNull().unique()
                t.column("sourceBundleID", .text)
                t.column("sourceName", .text)
                t.column("device", .text).notNull()
                t.column("firstCopiedAt", .datetime).notNull()
                t.column("lastCopiedAt", .datetime).notNull().indexed()
                t.column("lastUsedAt", .datetime).notNull().indexed()
            }
            try db.create(table: "representation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("itemID", .integer).notNull().indexed().references("item", onDelete: .cascade)
                t.column("itemIndex", .integer).notNull()
                t.column("position", .integer).notNull()
                t.column("type", .text).notNull()
                t.column("inlineData", .blob)
                t.column("blobHash", .text).indexed()
                t.column("byteCount", .integer).notNull()
            }
            try db.create(table: "category") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("visibility", .text).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(table: "categoryMembership") { t in
                t.column("categoryID", .integer).notNull().references("category", onDelete: .cascade)
                t.column("itemID", .integer).notNull().indexed().references("item", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.primaryKey(["categoryID", "itemID"])
            }
        }
        // Identity moved from "every type" to "what the user copied" (the text, image or files):
        // re-hash every item and fold copies that differed only in app extras into the newest one.
        migrator.registerMigration(contentIdentityMigration) { db in
            var kept: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, kind FROM item ORDER BY lastCopiedAt DESC, id DESC") {
                let id: Int64 = row["id"]
                guard let kind = ItemKind(rawValue: row["kind"]) else { continue }
                var items: [[PasteboardRepresentation]] = []
                var readable = true
                for rep in try StoredRepresentation.filter(Column("itemID") == id).order(Column("itemIndex"), Column("position")).fetchAll(db) {
                    guard let data = rep.inlineData ?? (try? blobs.read(rep.blobHash ?? "")) else { readable = false; break }
                    while items.count <= rep.itemIndex { items.append([]) }
                    items[rep.itemIndex].append(PasteboardRepresentation(type: rep.type, data: data))
                }
                guard readable else { continue }
                let hash = ItemStore.identityHash(items, kind: kind, hashes: items.map { $0.map { BlobStore.hash($0.data) } })
                guard let newer = kept[hash] else {
                    kept[hash] = id
                    try db.execute(sql: "UPDATE item SET contentHash = ? WHERE id = ?", arguments: [hash, id])
                    continue
                }
                try db.execute(sql: """
                    UPDATE item SET
                      firstCopiedAt = MIN(firstCopiedAt, (SELECT firstCopiedAt FROM item WHERE id = :old)),
                      lastUsedAt = MAX(lastUsedAt, (SELECT lastUsedAt FROM item WHERE id = :old))
                    WHERE id = :new
                    """, arguments: ["old": id, "new": newer])
                try db.execute(sql: """
                    INSERT OR IGNORE INTO categoryMembership (categoryID, itemID, position)
                    SELECT categoryID, ?, position FROM categoryMembership WHERE itemID = ?
                    """, arguments: [newer, id])
                // Foreign keys are off during migrations, so delete the dependents explicitly.
                try db.execute(sql: "DELETE FROM categoryMembership WHERE itemID = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM representation WHERE itemID = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [id])
            }
        }
        // An item can leave history while staying in its categories (⌘⌫ in the history column).
        migrator.registerMigration("v3-in-history") { db in
            try db.alter(table: "item") { t in
                t.add(column: "inHistory", .boolean).notNull().defaults(to: true)
            }
        }
        // Tags extensions' detectors put on items.
        migrator.registerMigration("v4-item-tags") { db in
            try db.create(table: "itemTag") { t in
                t.column("itemID", .integer).notNull().references("item", onDelete: .cascade)
                t.column("extensionID", .text).notNull()
                t.column("tag", .text).notNull()
                t.primaryKey(["itemID", "extensionID", "tag"])
            }
        }
        // A source an extension provides opens its own category; the key is "<extension id>/<source id>".
        // The person's categories keep a NULL.
        migrator.registerMigration("v5-category-source") { db in
            try db.alter(table: "category") { t in t.add(column: "source", .text) }
            try db.create(index: "categorySource", on: "category", columns: ["source"], unique: true, condition: Column("source") != nil)
        }
        // Which items of another clipboard manager's library were imported: a deleted item's row stays,
        // so it does not come back. No foreign key to item on purpose.
        migrator.registerMigration("v6-import-origin") { db in
            try db.create(table: "importOrigin") { t in
                t.column("source", .text).notNull()
                t.column("externalID", .text).notNull()
                t.column("itemID", .integer)
                t.primaryKey(["source", "externalID"])
            }
        }
        return migrator
    }

    static let contentIdentityMigration = "v2-content-identity"
}

/// One stored pasteboard representation; large payloads live in the blob store.
struct StoredRepresentation: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "representation"
    var id: Int64?
    var itemID: Int64
    var itemIndex: Int
    var position: Int
    var type: String
    var inlineData: Data?
    var blobHash: String?
    var byteCount: Int
}
