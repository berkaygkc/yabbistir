import Foundation
import Testing
import YabCore
import YabTestSupport
@testable import YabExtensions

@MainActor @Suite struct SourceCategoriesTests {
    private func source(_ extensionID: String, _ id: String, _ title: String) -> SourceDescriptor {
        SourceDescriptor(extensionID: extensionID, extensionName: "Kasa", sourceID: id, title: title, sensitive: true,
                         actions: [SourceActionDescriptor(id: "password", kind: .secret, title: "Şifreyi yapıştır", label: "Şifre")])
    }

    @Test func syncFollowsTheUsableSources() throws {
        let library = try Library(store: ItemStore(directory: TestScratch.url("items")))
        var changes = 0
        library.onChange = { changes += 1 }
        let mine = try library.createCategory(name: "İş")
        changes = 0

        SourceCategories.sync(library: library, sources: [source("dev.ornek", "vault", "Kasa")])
        #expect(try library.store.categories().map(\.name) == ["İş", "Kasa"])
        #expect(changes == 1)

        // Nothing new: nothing fires.
        SourceCategories.sync(library: library, sources: [source("dev.ornek", "vault", "Kasa")])
        #expect(changes == 1)

        SourceCategories.sync(library: library, sources: [source("dev.ornek", "vault", "Vault")])
        #expect(try library.store.categories().map(\.name) == ["İş", "Vault"])

        SourceCategories.sync(library: library, sources: [])
        #expect(try library.store.categories().map(\.id) == [mine.id])
    }
}
