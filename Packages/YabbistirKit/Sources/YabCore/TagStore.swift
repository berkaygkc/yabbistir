import Foundation
import GRDB

/// A tag a detector put on an item ("base64" from dev.yabbistir.base64).
public struct StoredTag: Hashable, Codable, Sendable {
    public let extensionID: String
    public let tag: String

    public init(extensionID: String, tag: String) {
        self.extensionID = extensionID
        self.tag = tag
    }
}

/// Detector tags, stored per item and extension; they go with their item.
extension ItemStore {
    /// Replaces one extension's tags on an item.
    public func setTags(_ tags: [StoredTag], for itemID: Int64, extensionID: String) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM itemTag WHERE itemID = ? AND extensionID = ?", arguments: [itemID, extensionID])
            for tag in tags where tag.extensionID == extensionID {
                try db.execute(sql: "INSERT OR IGNORE INTO itemTag (itemID, extensionID, tag) VALUES (?, ?, ?)",
                               arguments: [itemID, extensionID, tag.tag])
            }
        }
    }

    public func tags(ofItem itemID: Int64) throws -> [StoredTag] {
        try tags(of: [itemID])[itemID] ?? []
    }

    /// Tags of the given items; items without tags are left out.
    public func tags(of ids: [Int64]) throws -> [Int64: [StoredTag]] {
        guard !ids.isEmpty else { return [:] }
        let rows = try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT itemID, extensionID, tag FROM itemTag
                WHERE itemID IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                ORDER BY extensionID, tag
                """, arguments: StatementArguments(ids))
        }
        var tags: [Int64: [StoredTag]] = [:]
        for row in rows { tags[row["itemID"], default: []].append(StoredTag(extensionID: row["extensionID"], tag: row["tag"])) }
        return tags
    }

    /// Every item id after `id`, oldest first, a page at a time (detectors scanning old items).
    public func itemIDs(after id: Int64?, limit: Int) throws -> [Int64] {
        try dbPool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM item WHERE id > ? ORDER BY id LIMIT ?", arguments: [id ?? 0, limit])
        }
    }
}
