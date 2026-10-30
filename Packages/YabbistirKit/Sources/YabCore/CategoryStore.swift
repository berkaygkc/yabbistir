import Foundation
import GRDB

public enum CategoryVisibility: String, Codable, Sendable {
    case always, onSelect

    /// New categories (⌘P, the editor, Paste pinboards) open only on request, so the panel never floods.
    public static let `default`: CategoryVisibility = .onSelect
}

public enum CategoryColor: String, Codable, Sendable, CaseIterable {
    case slate, sage, clay, ochre, plum, teal
}

public struct ClipCategory: Codable, Sendable, Identifiable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "category"
    public var id: Int64?
    public var name: String
    public var color: CategoryColor
    public var visibility: CategoryVisibility
    public var position: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum CategoryError: Error, Equatable {
    case emptyName, duplicateName
}

/// Categories are ordered columns; an item in a category is kept for good, even after it
/// leaves history. Items that are in neither history nor any category are deleted.
extension ItemStore {
    public func categories() throws -> [ClipCategory] {
        try dbPool.read { db in try ClipCategory.order(Column("position"), Column("id")).fetchAll(db) }
    }

    public func createCategory(name: String, color: CategoryColor, visibility: CategoryVisibility = .default) throws -> ClipCategory {
        try dbPool.write { db in
            let name = try Self.validatedName(name, excluding: nil, db)
            let position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM category") ?? 0
            var category = ClipCategory(id: nil, name: name, color: color, visibility: visibility, position: position)
            try category.insert(db)
            return category
        }
    }

    /// The first palette color no category uses yet.
    public func nextCategoryColor() throws -> CategoryColor {
        let used = Set(try categories().map(\.color))
        return CategoryColor.allCases.first { !used.contains($0) } ?? .teal
    }

    /// Saves a rename, color or visibility change; the name follows the same rules as creation.
    public func updateCategory(_ category: ClipCategory) throws {
        try dbPool.write { db in
            var category = category
            category.name = try Self.validatedName(category.name, excluding: category.id, db)
            try category.update(db)
        }
    }

    public func moveCategory(id: Int64, to index: Int) throws {
        try dbPool.write { db in
            var ordered = try ClipCategory.order(Column("position"), Column("id")).fetchAll(db)
            guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
            let moved = ordered.remove(at: from)
            ordered.insert(moved, at: max(0, min(index, ordered.count)))
            for (position, var category) in ordered.enumerated() where category.position != position {
                category.position = position
                try category.update(db)
            }
        }
    }

    /// Deletes a category; its items stay unless they were kept only by it. Returns the deleted item ids.
    public func deleteCategory(id: Int64) throws -> [Int64] {
        try dbPool.write { db in
            let members = try Int64.fetchAll(db, sql: "SELECT itemID FROM categoryMembership WHERE categoryID = ?", arguments: [id])
            _ = try ClipCategory.deleteOne(db, key: id)
            let orphans = try Self.orphans(among: members, db)
            try deleteItems(orphans, db)
            return orphans
        }
    }

    public func add(itemID: Int64, toCategory categoryID: Int64) throws {
        try dbPool.write { db in
            let position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM categoryMembership WHERE categoryID = ?",
                                            arguments: [categoryID]) ?? 0
            try db.execute(sql: "INSERT OR IGNORE INTO categoryMembership (categoryID, itemID, position) VALUES (?, ?, ?)",
                           arguments: [categoryID, itemID, position])
        }
    }

    /// Takes an item out of a category; returns true when that deleted it (it was in nothing else).
    public func remove(itemID: Int64, fromCategory categoryID: Int64) throws -> Bool {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM categoryMembership WHERE categoryID = ? AND itemID = ?", arguments: [categoryID, itemID])
            let orphans = try Self.orphans(among: [itemID], db)
            try deleteItems(orphans, db)
            return !orphans.isEmpty
        }
    }

    /// ⌘⌫ in the history column: a categorized item only leaves history (returns false);
    /// anything else is deleted (returns true).
    public func deleteFromHistory(_ itemID: Int64) throws -> Bool {
        try dbPool.write { db in
            let categorized = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM categoryMembership WHERE itemID = ?)",
                                                arguments: [itemID]) ?? false
            if categorized {
                try db.execute(sql: "UPDATE item SET inHistory = 0 WHERE id = ?", arguments: [itemID])
                return false
            }
            try deleteItems([itemID], db)
            return true
        }
    }

    /// The category's items, most recently added first.
    public func itemIDs(inCategory categoryID: Int64) throws -> [Int64] {
        try dbPool.read { db in
            try Int64.fetchAll(db, sql: "SELECT itemID FROM categoryMembership WHERE categoryID = ? ORDER BY position DESC",
                               arguments: [categoryID])
        }
    }

    /// The categories an item belongs to, in column order.
    public func categoryIDs(ofItem itemID: Int64) throws -> [Int64] {
        try dbPool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT c.id FROM category c JOIN categoryMembership m ON m.categoryID = c.id
                WHERE m.itemID = ? ORDER BY c.position, c.id
                """, arguments: [itemID])
        }
    }

    public func itemCounts() throws -> [Int64: Int] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT categoryID, COUNT(*) AS n FROM categoryMembership GROUP BY categoryID")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["categoryID"] as Int64, $0["n"] as Int) })
        }
    }

    /// Trimmed, non-empty and unique under Turkish folding ("İş" and "iş" are the same name).
    static func validatedName(_ raw: String, excluding id: Int64?, _ db: Database) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CategoryError.emptyName }
        let folded = SearchNormalizer.normalize(name)
        if try ClipCategory.fetchAll(db).contains(where: { $0.id != id && SearchNormalizer.normalize($0.name) == folded }) {
            throw CategoryError.duplicateName
        }
        return name
    }

    /// Items among `ids` that are in neither history nor any category.
    static func orphans(among ids: [Int64], _ db: Database) throws -> [Int64] {
        guard !ids.isEmpty else { return [] }
        return try Int64.fetchAll(db, sql: """
            SELECT id FROM item
            WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ","))) AND inHistory = 0
              AND NOT EXISTS (SELECT 1 FROM categoryMembership m WHERE m.itemID = item.id)
            """, arguments: StatementArguments(ids))
    }
}
