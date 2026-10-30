import Foundation
import Testing
@testable import YabCore

@MainActor @Suite struct LibraryTests {
    @Test func deletingFromHistoryUpdatesIndexAndNotifies() throws {
        let library = try Library(store: ItemStore.temporary())
        var changes = 0
        library.onChange = { changes += 1 }
        let item = try #require(try library.store.ingest(textClip("sil", at: t0))).item
        library.didIngest(item)
        try library.deleteFromHistory(item.id!)
        #expect(library.index.search("", limit: 10).ids.isEmpty)
        #expect(changes == 2)
    }

    @Test func toggleAddsThenRemovesMembership() throws {
        let library = try Library(store: ItemStore.temporary())
        let cat = try library.createCategory(name: "Kod")
        let item = try #require(try library.store.ingest(textClip("x", at: t0))).item
        library.didIngest(item)
        try library.toggle(item.id!, inCategory: cat.id!)
        #expect(try library.store.itemIDs(inCategory: cat.id!) == [item.id!])
        try library.toggle(item.id!, inCategory: cat.id!)
        #expect(try library.store.itemIDs(inCategory: cat.id!).isEmpty)
    }
}
