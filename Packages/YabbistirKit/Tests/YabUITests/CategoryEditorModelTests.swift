import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabTestSupport
@testable import YabUI

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

private func clip(_ s: String, minutesAgo: Double) -> CapturedClip {
    CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(s.utf8))]],
                 source: nil, device: .local, capturedAt: now.addingTimeInterval(-minutesAgo * 60))
}

/// "Kod" (always) holds two items, "Bağlantılar" (on select) one; the panel model listens to the library.
@MainActor @Suite struct CategoryEditorModelTests {
    let library: Library
    let model: PanelViewModel
    let editor: CategoryEditorModel
    let code: ClipCategory
    let links: ClipCategory

    init() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        var ids: [Int64] = []
        for (offset, text) in ["SELECT 1", "UPDATE t", "https://example.com"].enumerated() {
            ids.append(try #require(try store.ingest(clip(text, minutesAgo: Double(offset)))).item.id!)
        }
        code = try store.createCategory(name: "Kod", color: .slate, visibility: .always)
        links = try store.createCategory(name: "Bağlantılar", color: .sage)
        try store.add(itemID: ids[0], toCategory: code.id!)
        try store.add(itemID: ids[1], toCategory: code.id!)
        try store.add(itemID: ids[2], toCategory: links.id!)
        library = try Library(store: store)
        let language = LanguageStore(defaults: TestScratch.defaults("yab-editor"), preferredLanguages: ["en"])
        language.language = .turkish
        model = PanelViewModel(library: library, language: language, now: { now })
        library.onChange = { [model] in model.refresh() }
        model.reset()
        editor = CategoryEditorModel(library: library, language: language)
    }

    @Test func renameRejectsBlankAndDuplicateNames() throws {
        #expect(!editor.rename(code.id!, to: "  "))
        #expect(!editor.rename(code.id!, to: "bağlantılar"))
        #expect(editor.rename(code.id!, to: "Kod parçaları"))
        #expect(try library.store.categories().first?.name == "Kod parçaları")
    }
    @Test func newCategoryNamesCountUp() throws {
        editor.addCategory(); editor.addCategory()
        #expect(try library.store.categories().suffix(2).map(\.name) == ["Yeni kategori", "Yeni kategori 2"])
    }
    @Test func moveReordersColumnsLive() {
        model.toggleShown(links.id!)
        #expect(model.columns.map(\.title) == ["Geçmiş", "Kod", "Bağlantılar"])
        editor.move(from: 0, to: 1)
        #expect(model.columns.map(\.title) == ["Geçmiş", "Bağlantılar", "Kod"])
        #expect(editor.rows.map(\.category.name) == ["Bağlantılar", "Kod"])
    }
    @Test func deletingACategoryRemovesItsColumn() throws {
        editor.delete(code.id!)
        #expect(editor.rows.map(\.category.name) == ["Bağlantılar"])
        #expect(model.columns.count == 1)
    }

    @Test func selectionStartsOnTheFirstRowAndClamps() {
        #expect(editor.selectedID == code.id)
        editor.moveSelection(by: -1)
        #expect(editor.selectedID == code.id)
        editor.moveSelection(by: 5)
        #expect(editor.selectedID == links.id)
    }

    @Test func tabTogglesTheSelectedCategorysVisibility() throws {
        editor.moveSelection(by: 1)
        editor.toggleSelectedVisibility()
        #expect(try library.store.categories().first { $0.id == links.id }?.visibility == .always)
        editor.toggleSelectedVisibility()
        #expect(try library.store.categories().first { $0.id == links.id }?.visibility == .onSelect)
    }

    @Test func selectionFollowsTheCategoryAcrossChanges() {
        editor.moveSelection(by: 1)
        editor.rename(links.id!, to: "Linkler")
        #expect(editor.selectedID == links.id)
        editor.delete(links.id!)
        #expect(editor.selectedID == code.id)
    }

    @Test func aNewCategoryIsSelectedForTyping() throws {
        editor.addCategory()
        let created = try #require(try library.store.categories().last)
        #expect(created.name == "Yeni kategori")
        #expect(editor.selectedID == created.id)
    }

    // MARK: A source's category

    static let vaultKey = "dev.example.kasa/vault"

    /// The vault's category, made by its extension, after the person's two; the editor reads its rows from `sources`.
    private func addVault(sources: FakeSources? = nil) throws -> (CategoryEditorModel, CategoryEditorModel.Row) {
        try library.syncSourceCategories([SourceCategorySeed(key: Self.vaultKey, name: "Kasa")])
        let language = LanguageStore(defaults: TestScratch.defaults("yab-editor-src"), preferredLanguages: ["en"])
        language.language = .turkish
        let editor = CategoryEditorModel(library: library, language: language, sources: sources)
        return (editor, try #require(editor.rows.first { $0.isSource }))
    }

    /// Its extension names and fills it: the editor keeps its name, colour and existence as they are, and says so.
    @Test func aSourceCategoryCannotBeRenamedRecolouredOrDeletedInTheEditor() throws {
        let (editor, vault) = try addVault()
        #expect(vault.category.name == "Kasa")
        #expect(editor.rows.map(\.isSource) == [false, false, true])
        let color = vault.category.color
        let other = try #require(CategoryColor.allCases.first { $0 != color })
        #expect(!editor.rename(vault.id, to: "Şifreler"))
        #expect(!editor.setColor(vault.id, other))
        #expect(!editor.delete(vault.id))
        let stored = try #require(try library.store.categories().first { $0.source == Self.vaultKey })
        #expect(stored.name == "Kasa")
        #expect(stored.color == color)
        #expect(editor.rows.map(\.category.name) == ["Kod", "Bağlantılar", "Kasa"])
        // The person's own still change.
        #expect(editor.setColor(code.id!, other))
        #expect(editor.delete(links.id!))
        #expect(editor.rows.map(\.category.name) == ["Kod", "Kasa"])
    }

    /// Visibility (the segments and ⇥) and order (dragging) are the person's, for a source's category too; its count is
    /// the rows its list holds, and nothing while it has none at hand.
    @Test func theEditorKeepsVisibilityAndOrderForSources() throws {
        let sources = FakeSources()
        sources.descriptors = [FakeSources.vault()]
        sources.states[Self.vaultKey] = .rows([SourceRow(id: "1", title: "Kodhane", subtitle: "deniz.k"), SourceRow(id: "2", title: "ornek.dev")])
        let (editor, vault) = try addVault(sources: sources)
        func stored() throws -> ClipCategory { try #require(try library.store.categories().first { $0.source == Self.vaultKey }) }
        #expect(vault.count == 2)
        #expect(editor.rows.first { $0.id == code.id }?.count == 2)

        editor.moveSelection(by: 2)
        #expect(editor.selectedID == vault.id)
        editor.toggleSelectedVisibility()
        #expect(try stored().visibility == .always)
        editor.setVisibility(vault.id, .onSelect)
        #expect(try stored().visibility == .onSelect)

        editor.move(from: 2, to: 0)
        #expect(editor.rows.map(\.category.name) == ["Kasa", "Kod", "Bağlantılar"])
        #expect(editor.selectedID == vault.id)
        editor.moveSelection(by: 1)
        #expect(editor.selectedID == code.id)

        sources.states[Self.vaultKey] = .locked(message: "Kasa kilitli", command: nil)
        editor.reload()
        #expect(editor.rows.first { $0.id == vault.id }?.count == nil)
    }
}
