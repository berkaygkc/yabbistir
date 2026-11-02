import Foundation
import Testing
@testable import YabCore

private let day: TimeInterval = 86_400

private func importedClip(_ text: String, id: String = "ext-1", first: Date, last: Date) -> ImportedClip {
    ImportedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                 source: SourceApp(bundleID: "com.example.Editor", name: "Editor"), device: .local,
                 firstCopiedAt: first, lastCopiedAt: last, externalID: id)
}

@Suite struct ImportedItemsTests {
    let now = t0

    @Test func importedOldItemsSurviveTheNextPurge() throws {
        let store = try ItemStore.temporary()
        let old = now.addingTimeInterval(-730 * day)
        let outcome = try store.importClip(importedClip("eski kayıt", first: old, last: old), from: "other", usedAt: now)
        guard case .added(let id) = outcome else { Issue.record("expected added"); return }
        #expect(try store.countExpired(policy: .oneYear, now: now) == 0)
        #expect(try store.purgeExpired(policy: .oneYear, now: now).isEmpty)
        let item = try #require(try store.item(id: id))
        #expect(item.lastCopiedAt == old)
        #expect(item.lastUsedAt == now)
    }

    @Test func anExistingItemKeepsItsNewerDates() throws {
        let store = try ItemStore.temporary()
        let yesterday = now.addingTimeInterval(-day)
        let year = now.addingTimeInterval(-365 * day)
        let existing = try #require(try store.ingest(textClip("aynı içerik", at: yesterday)))
        let outcome = try store.importClip(importedClip("aynı içerik", first: year, last: year), from: "other", usedAt: now)
        #expect(outcome == .merged(existing.item.id!))
        let item = try #require(try store.item(id: existing.item.id!))
        #expect(item.lastCopiedAt == yesterday)
        #expect(item.firstCopiedAt == year)
        #expect(item.sourceName == "TextEdit")
    }

    @Test func theSameExternalIDIsImportedOnce() throws {
        let store = try ItemStore.temporary()
        let clip = importedClip("bir kez", first: now, last: now)
        _ = try store.importClip(clip, from: "other", usedAt: now)
        #expect(try store.importClip(clip, from: "other", usedAt: now) == .alreadyImported)
        #expect(try store.history(limit: 10).count == 1)
    }

    @Test func aDeletedImportedItemStaysDeleted() throws {
        let store = try ItemStore.temporary()
        let clip = importedClip("silinecek", first: now, last: now)
        guard case .added(let id) = try store.importClip(clip, from: "other", usedAt: now) else { Issue.record("expected added"); return }
        try store.delete(id)
        #expect(try store.importClip(clip, from: "other", usedAt: now) == .alreadyImported)
        #expect(try store.history(limit: 10).isEmpty)
    }

    @Test func unclassifiableContentIsRecordedAndNotRetried() throws {
        let store = try ItemStore.temporary()
        let clip = ImportedClip(items: [], source: nil, device: .local, firstCopiedAt: now, lastCopiedAt: now, externalID: "empty")
        #expect(try store.importClip(clip, from: "other", usedAt: now) == .nothingToKeep)
        #expect(try store.importClip(clip, from: "other", usedAt: now) == .alreadyImported)
    }

    @Test func hideFromHistoryKeepsACategorizedItem() throws {
        let store = try ItemStore.temporary()
        let result = try #require(try store.ingest(textClip("kategorili", at: now)))
        let category = try store.createCategory(name: "Not", color: .slate)
        try store.add(itemID: result.item.id!, toCategory: category.id!)
        try store.hideFromHistory(result.item.id!)
        #expect(try store.item(id: result.item.id!)?.inHistory == false)
    }

    @MainActor @Test func reloadIndexNotifiesOnce() throws {
        let library = try Library(store: ItemStore.temporary())
        var calls = 0
        library.onChange = { calls += 1 }
        _ = try library.store.importClip(importedClip("dizine girer", first: now, last: now), from: "other", usedAt: now)
        #expect(library.index.search("dizine", limit: 10).total == 0)
        try library.reloadIndex()
        #expect(calls == 1)
        #expect(library.index.search("dizine", limit: 10).total == 1)
    }
}
