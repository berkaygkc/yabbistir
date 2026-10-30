import Foundation
import Testing
import YabCore
import YabLocalization
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
        let store = try ItemStore.temporary()
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
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-editor-\(UUID().uuidString)")!)
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
}
