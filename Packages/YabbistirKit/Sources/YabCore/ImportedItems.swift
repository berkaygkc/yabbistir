import Foundation
import GRDB

/// One item read from another clipboard manager's library.
public struct ImportedClip: Sendable {
    public var items: [[PasteboardRepresentation]]
    public var source: SourceApp?
    public var device: DeviceKind
    public var firstCopiedAt: Date
    public var lastCopiedAt: Date
    /// The item's identity in the library it came from; an item is imported once per `externalID`.
    public var externalID: String

    public init(items: [[PasteboardRepresentation]], source: SourceApp?, device: DeviceKind,
                firstCopiedAt: Date, lastCopiedAt: Date, externalID: String) {
        self.items = items
        self.source = source
        self.device = device
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.externalID = externalID
    }
}

public enum ImportOutcome: Equatable, Sendable {
    case added(Int64)
    case merged(Int64)
    case alreadyImported
    case nothingToKeep
}

extension ItemStore {
    /// Writes an item of another library, once per `(source, externalID)`. The original dates are kept;
    /// `usedAt` becomes the retention date, so old imports are not purged on the next sweep. An item whose
    /// content already exists only has its dates merged: its source, device and representations stay.
    public func importClip(_ clip: ImportedClip, from source: String, usedAt: Date) throws -> ImportOutcome {
        func isMapped(_ db: Database) throws -> Bool {
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM importOrigin WHERE source = ? AND externalID = ?)",
                              arguments: [source, clip.externalID]) ?? false
        }
        // Checked before preparing so a repeated import writes no blob files.
        if try dbPool.read(isMapped) { return .alreadyImported }
        let prepared = try prepare(clip.items)

        return try dbPool.write { db in
            if try isMapped(db) { return .alreadyImported }
            func record(_ itemID: Int64?) throws {
                try db.execute(sql: "INSERT INTO importOrigin (source, externalID, itemID) VALUES (?, ?, ?)",
                               arguments: [source, clip.externalID, itemID])
            }
            guard let prepared else {
                try record(nil)
                return .nothingToKeep
            }
            if var existing = try ClipItem.filter(Column("contentHash") == prepared.identity).fetchOne(db), let id = existing.id {
                existing.firstCopiedAt = min(existing.firstCopiedAt, clip.firstCopiedAt)
                existing.lastCopiedAt = max(existing.lastCopiedAt, clip.lastCopiedAt)
                existing.lastUsedAt = max(existing.lastUsedAt, usedAt)
                try existing.update(db)
                try record(id)
                return .merged(id)
            }
            var item = ClipItem(
                id: nil, kind: prepared.classification.kind, previewText: prepared.classification.previewText,
                searchText: prepared.classification.searchText, contentHash: prepared.identity,
                sourceBundleID: clip.source?.bundleID, sourceName: clip.source?.name, device: clip.device,
                firstCopiedAt: clip.firstCopiedAt, lastCopiedAt: clip.lastCopiedAt, lastUsedAt: usedAt)
            try item.insert(db)
            try insertRepresentations(prepared.stored, itemID: item.id!, db)
            try record(item.id)
            return .added(item.id!)
        }
    }

    /// Takes a categorized item out of history; the category keeps it.
    public func hideFromHistory(_ itemID: Int64) throws {
        try dbPool.write { db in try hideFromHistory(itemID, db) }
    }
}
