import Foundation
import GRDB
import Testing
import YabTestSupport
@testable import YabCore

@Suite struct CategoryStoreTests {
    @Test func createTrimsAndRejectsBlankOrDuplicateNames() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let work = try store.createCategory(name: "  İş  ", color: .slate)
        #expect(work.name == "İş")
        #expect(work.visibility == .onSelect)
        #expect(throws: CategoryError.emptyName) { try store.createCategory(name: "   ", color: .sage) }
        #expect(throws: CategoryError.duplicateName) { try store.createCategory(name: "iş", color: .sage) }
    }

    @Test func nextColorSkipsUsedColors() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.createCategory(name: "A", color: .slate)
        _ = try store.createCategory(name: "B", color: .sage)
        #expect(try store.nextCategoryColor() == .clay)
    }

    @Test func moveRenumbersPositions() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let a = try store.createCategory(name: "A", color: .slate)
        _ = try store.createCategory(name: "B", color: .sage)
        _ = try store.createCategory(name: "C", color: .clay)
        try store.moveCategory(id: a.id!, to: 2)
        #expect(try store.categories().map(\.name) == ["B", "C", "A"])
        #expect(try store.categories().map(\.position) == [0, 1, 2])
    }

    @Test func categoryListsNewestMembershipFirst() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let cat = try store.createCategory(name: "A", color: .slate)
        let x = try #require(try store.ingest(textClip("x", at: t0))).item.id!
        let y = try #require(try store.ingest(textClip("y", at: t0.addingTimeInterval(1)))).item.id!
        try store.add(itemID: x, toCategory: cat.id!)
        try store.add(itemID: y, toCategory: cat.id!)
        #expect(try store.itemIDs(inCategory: cat.id!) == [y, x])
    }

    @Test func deletingACategorizedItemFromHistoryKeepsItInTheCategory() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let cat = try store.createCategory(name: "A", color: .slate)
        let id = try #require(try store.ingest(textClip("sabit", at: t0))).item.id!
        try store.add(itemID: id, toCategory: cat.id!)
        #expect(try store.deleteFromHistory(id) == false)
        #expect(try store.item(id: id)?.inHistory == false)
        #expect(try store.itemIDs(inCategory: cat.id!) == [id])
    }

    @Test func removingTheLastCategoryOfAHiddenItemDeletesIt() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let cat = try store.createCategory(name: "A", color: .slate)
        let id = try #require(try store.ingest(textClip("sabit", at: t0))).item.id!
        try store.add(itemID: id, toCategory: cat.id!)
        _ = try store.deleteFromHistory(id)
        #expect(try store.remove(itemID: id, fromCategory: cat.id!) == true)
        #expect(try store.item(id: id) == nil)
    }

    @Test func recopyOrPasteBringsAHiddenItemBackToHistory() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let cat = try store.createCategory(name: "A", color: .slate)
        let id = try #require(try store.ingest(textClip("sabit", at: t0))).item.id!
        try store.add(itemID: id, toCategory: cat.id!)
        _ = try store.deleteFromHistory(id)
        try store.markUsed(id, at: t0.addingTimeInterval(5))
        #expect(try store.item(id: id)?.inHistory == true)
    }

    @Test func deletingACategoryKeepsItemsThatAreStillInHistory() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
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

    // MARK: Source categories

    @Test func aSourceCategoryIsCreatedAtTheEndAndOpensOnSelect() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.createCategory(name: "İş", color: .slate)
        #expect(try store.syncSourceCategories([SourceCategorySeed(key: "dev.ornek/vault", name: "Kasa")]))
        let all = try store.categories()
        #expect(all.map(\.name) == ["İş", "Kasa"])
        let source = try #require(all.last)
        #expect(source.source == "dev.ornek/vault")
        #expect(source.isSource)
        #expect(source.visibility == .onSelect)
        #expect(source.position == 1)
        #expect(!all[0].isSource)
    }

    @Test func syncRemovesCategoriesOfGoneSourcesAndKeepsThePersons() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let mine = try store.createCategory(name: "İş", color: .slate)
        _ = try store.syncSourceCategories([SourceCategorySeed(key: "a/one", name: "Bir"), SourceCategorySeed(key: "a/two", name: "İki")])
        #expect(try store.syncSourceCategories([SourceCategorySeed(key: "a/two", name: "İki")]))
        #expect(try store.categories().map(\.name) == ["İş", "İki"])
        #expect(try store.syncSourceCategories([]))
        #expect(try store.categories().map(\.id) == [mine.id])
        // Coming back puts it at the end again.
        _ = try store.syncSourceCategories([SourceCategorySeed(key: "a/one", name: "Bir")])
        #expect(try store.categories().map(\.name) == ["İş", "Bir"])
    }

    @Test func syncIsIdempotent() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let wanted = [SourceCategorySeed(key: "a/one", name: "Bir")]
        #expect(try store.syncSourceCategories(wanted))
        #expect(try !store.syncSourceCategories(wanted))
        #expect(try store.categories().count == 1)
    }

    @Test func aRenamedSourceRenamesItsCategory() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.syncSourceCategories([SourceCategorySeed(key: "a/one", name: "Kasa")])
        let id = try #require(try store.categories().first?.id)
        #expect(try store.syncSourceCategories([SourceCategorySeed(key: "a/one", name: "Vault")]))
        let category = try #require(try store.categories().first)
        #expect(category.id == id)
        #expect(category.name == "Vault")
    }

    @Test func aSourceCategoryCannotBeRenamedDeletedOrFilled() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.syncSourceCategories([SourceCategorySeed(key: "a/one", name: "Kasa")])
        var category = try #require(try store.categories().first)
        let id = try #require(category.id)
        category.name = "Başka"
        #expect(throws: CategoryError.managedByExtension) { try store.updateCategory(category) }
        #expect(throws: CategoryError.managedByExtension) { try store.deleteCategory(id: id) }
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("merhaba".utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        let item = try #require(try store.ingest(clip)).item.id!
        #expect(throws: CategoryError.managedByExtension) { try store.add(itemID: item, toCategory: id) }
        #expect(try store.itemIDs(inCategory: id).isEmpty)
        #expect(try store.categories().map(\.name) == ["Kasa"])
    }

    @Test func visibilityAndOrderWorkLikeAnyCategory() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        let mine = try store.createCategory(name: "İş", color: .slate)
        _ = try store.syncSourceCategories([SourceCategorySeed(key: "a/one", name: "Kasa")])
        var source = try #require(try store.categories().last)
        source.visibility = .always
        try store.updateCategory(source)
        try store.moveCategory(id: try #require(source.id), to: 0)
        let all = try store.categories()
        #expect(all.map(\.name) == ["Kasa", "İş"])
        #expect(all[0].visibility == .always)
        #expect(all[0].source == "a/one")
        #expect(all[1].id == mine.id)
    }

    @Test func aPersonsCategoryMayShareASourcesName() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.createCategory(name: "Kasa", color: .slate)
        _ = try store.syncSourceCategories([SourceCategorySeed(key: "a/one", name: "kasa")])
        #expect(try store.categories().count == 2)
        // And the person may name one after a source later.
        _ = try store.createCategory(name: "KASA 2", color: .sage)
        let mine = try store.createCategory(name: "Vault", color: .teal)
        _ = try store.syncSourceCategories([SourceCategorySeed(key: "a/one", name: "kasa"), SourceCategorySeed(key: "a/two", name: "Vault")])
        #expect(try store.categories().filter { $0.name == "Vault" }.count == 2)
        #expect(try store.categories().contains { $0.id == mine.id && !$0.isSource })
    }

    @Test func oldCategoriesHaveNoSourceAfterTheMigration() throws {
        let directory = TestScratch.url("yab-source")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let queue = try DatabaseQueue(path: directory.appendingPathComponent("db.sqlite").path)
            try Schema.migrator(blobs: BlobStore(directory: directory.appendingPathComponent("Blobs"))).migrate(queue, upTo: "v4-item-tags")
            try queue.write { db in
                try db.execute(sql: "INSERT INTO category (name, color, visibility, position) VALUES ('İş', 'slate', 'always', 0)")
            }
        }
        let store = try ItemStore(directory: directory)
        let all = try store.categories()
        #expect(all.map(\.name) == ["İş"])
        #expect(all[0].source == nil)
        #expect(all[0].visibility == .always)
    }
}
