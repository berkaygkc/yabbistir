import Foundation
import Testing
@testable import YabCore

@Suite struct CategoryStoreTests {
    @Test func createTrimsAndRejectsBlankOrDuplicateNames() throws {
        let store = try ItemStore.temporary()
        let work = try store.createCategory(name: "  İş  ", color: .slate)
        #expect(work.name == "İş")
        #expect(work.visibility == .onSelect)
        #expect(throws: CategoryError.emptyName) { try store.createCategory(name: "   ", color: .sage) }
        #expect(throws: CategoryError.duplicateName) { try store.createCategory(name: "iş", color: .sage) }
    }

    @Test func nextColorSkipsUsedColors() throws {
        let store = try ItemStore.temporary()
        _ = try store.createCategory(name: "A", color: .slate)
        _ = try store.createCategory(name: "B", color: .sage)
        #expect(try store.nextCategoryColor() == .clay)
    }

    @Test func moveRenumbersPositions() throws {
        let store = try ItemStore.temporary()
        let a = try store.createCategory(name: "A", color: .slate)
        _ = try store.createCategory(name: "B", color: .sage)
        _ = try store.createCategory(name: "C", color: .clay)
        try store.moveCategory(id: a.id!, to: 2)
        #expect(try store.categories().map(\.name) == ["B", "C", "A"])
        #expect(try store.categories().map(\.position) == [0, 1, 2])
    }

    @Test func categoryListsNewestMembershipFirst() throws {
        let store = try ItemStore.temporary()
        let cat = try store.createCategory(name: "A", color: .slate)
        let x = try #require(try store.ingest(textClip("x", at: t0))).item.id!
        let y = try #require(try store.ingest(textClip("y", at: t0.addingTimeInterval(1)))).item.id!
        try store.add(itemID: x, toCategory: cat.id!)
        try store.add(itemID: y, toCategory: cat.id!)
        #expect(try store.itemIDs(inCategory: cat.id!) == [y, x])
    }

    @Test func deletingACategorizedItemFromHistoryKeepsItInTheCategory() throws {
        let store = try ItemStore.temporary()
        let cat = try store.createCategory(name: "A", color: .slate)
        let id = try #require(try store.ingest(textClip("sabit", at: t0))).item.id!
        try store.add(itemID: id, toCategory: cat.id!)
        #expect(try store.deleteFromHistory(id) == false)
        #expect(try store.item(id: id)?.inHistory == false)
        #expect(try store.itemIDs(inCategory: cat.id!) == [id])
    }

    @Test func removingTheLastCategoryOfAHiddenItemDeletesIt() throws {
        let store = try ItemStore.temporary()
        let cat = try store.createCategory(name: "A", color: .slate)
        let id = try #require(try store.ingest(textClip("sabit", at: t0))).item.id!
        try store.add(itemID: id, toCategory: cat.id!)
        _ = try store.deleteFromHistory(id)
        #expect(try store.remove(itemID: id, fromCategory: cat.id!) == true)
        #expect(try store.item(id: id) == nil)
    }

    @Test func recopyOrPasteBringsAHiddenItemBackToHistory() throws {
        let store = try ItemStore.temporary()
        let cat = try store.createCategory(name: "A", color: .slate)
        let id = try #require(try store.ingest(textClip("sabit", at: t0))).item.id!
        try store.add(itemID: id, toCategory: cat.id!)
        _ = try store.deleteFromHistory(id)
        try store.markUsed(id, at: t0.addingTimeInterval(5))
        #expect(try store.item(id: id)?.inHistory == true)
    }

    @Test func deletingACategoryKeepsItemsThatAreStillInHistory() throws {
        let store = try ItemStore.temporary()
        let cat = try store.createCategory(name: "A", color: .slate)
        let kept = try #require(try store.ingest(textClip("geçmişte", at: t0))).item.id!
        let hidden = try #require(try store.ingest(textClip("yalnız kategoride", at: t0))).item.id!
        try store.add(itemID: kept, toCategory: cat.id!)
        try store.add(itemID: hidden, toCategory: cat.id!)
        _ = try store.deleteFromHistory(hidden)
        #expect(try store.deleteCategory(id: cat.id!) == [hidden])
        #expect(try store.item(id: kept) != nil)
        #expect(try store.categories().isEmpty)
    }
}
