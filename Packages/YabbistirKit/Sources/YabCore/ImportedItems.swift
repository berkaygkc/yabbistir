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

/// Where an imported item goes besides History: a category, and whether a new item stays out of History (one that
/// was only pinned in the other library).
public struct ImportFiling: Sendable, Equatable {
    public var categoryID: Int64
    public var hidesNewItem: Bool

    public init(categoryID: Int64, hidesNewItem: Bool) {
        self.categoryID = categoryID
        self.hidesNewItem = hidesNewItem
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
    /// With `filing`, the item joins that category in the same transaction as its mapping, so an import that stops
    /// partway never leaves an imported item unfiled.
    public func importClip(_ clip: ImportedClip, from source: String, usedAt: Date,
                           filing: ImportFiling? = nil) throws -> ImportOutcome {
        func isMapped(_ db: Database) throws -> Bool {
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM importOrigin WHERE source = ? AND externalID = ?)",
                              arguments: [source, clip.externalID]) ?? false
        }
        // Checked before preparing so a repeated import writes no blob files.
        if try dbPool.read(isMapped) { return .alreadyImported }
        let prepared = try prepare(clip.items)
        // The blob files `prepare` wrote. Whatever no representation ends up pointing at (a merge keeps the existing
        // representations) is removed again.
        let written = prepared?.stored.compactMap(\.record.blobHash) ?? []

        do {
            return try dbPool.write { db in
                if try isMapped(db) {
                    try removeUnreferencedBlobs(written, db)
                    return .alreadyImported
                }
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
                    // An item already here keeps its place in History.
                    if let filing { try addMembership(itemID: id, categoryID: filing.categoryID, db) }
                    try removeUnreferencedBlobs(written, db)
                    return .merged(id)
                }
                var item = ClipItem(
                    id: nil, kind: prepared.classification.kind, previewText: prepared.classification.previewText,
                    searchText: prepared.classification.searchText, contentHash: prepared.identity,
                    sourceBundleID: clip.source?.bundleID, sourceName: clip.source?.name, device: clip.device,
                    firstCopiedAt: clip.firstCopiedAt, lastCopiedAt: clip.lastCopiedAt, lastUsedAt: usedAt)
                if filing?.hidesNewItem == true { item.inHistory = false }
                try item.insert(db)
                try insertRepresentations(prepared.stored, itemID: item.id!, db)
                try record(item.id)
                if let filing { try addMembership(itemID: item.id!, categoryID: filing.categoryID, db) }
                return .added(item.id!)
            }
        } catch {
            // Nothing was written, so nothing points at the files prepared for it.
            if !written.isEmpty { try? dbPool.write { db in try removeUnreferencedBlobs(written, db) } }
            throw error
        }
    }
}
