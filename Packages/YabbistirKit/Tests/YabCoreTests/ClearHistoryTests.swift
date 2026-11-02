import Foundation
import Testing
@testable import YabCore

@MainActor @Suite struct ClearHistoryTests {
    @Test func clearHistoryReturnsTheDeletedIDs() throws {
        let library = try Library(store: ItemStore.temporary())
        let cat = try library.createCategory(name: "Kod")
        var ids: [Int64] = []
        for text in ["bir", "iki", "üç"] {
            let item = try #require(try library.store.ingest(textClip(text, at: t0))).item
            library.didIngest(item)
            ids.append(item.id!)
        }
        try library.add(ids[2], toCategory: cat.id!)
        var changes = 0
        library.onChange = { changes += 1 }

        let deleted = try library.clearHistory()

        #expect(Set(deleted) == Set(ids[0...1]))
        #expect(deleted.count == 2)
        #expect(changes == 1)
        #expect(try library.store.item(id: ids[2])?.inHistory == false)
        #expect(try library.store.item(id: ids[0]) == nil)
        #expect(library.itemIDs(inCategory: cat.id!) == [ids[2]])
        #expect(library.index.search("", limit: 10).ids.isEmpty)
    }

    @Test func clearingWhenEveryItemIsCategorizedHidesThemAll() throws {
        let library = try Library(store: ItemStore.temporary())
        let cat = try library.createCategory(name: "Kod")
        var ids: [Int64] = []
        for text in ["bir", "iki"] {
            let item = try #require(try library.store.ingest(textClip(text, at: t0))).item
            library.didIngest(item)
            try library.add(item.id!, toCategory: cat.id!)
            ids.append(item.id!)
        }

        let deleted = try library.clearHistory()

        #expect(deleted.isEmpty)
        #expect(library.index.search("", limit: 10).ids.isEmpty)
        #expect(Set(library.itemIDs(inCategory: cat.id!)) == Set(ids))
    }
}
