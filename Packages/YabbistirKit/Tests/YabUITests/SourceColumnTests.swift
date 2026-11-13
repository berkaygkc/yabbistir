import Foundation
import Testing
import YabTestSupport
@testable import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabPasteboard
@testable import YabUI

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

/// A source's column: its rows come from the sources (in memory), never from history; the app searches them.
@MainActor @Suite struct SourceColumnTests {
    static let vaultKey = "dev.example.kasa/vault"
    static let notesKey = "dev.example.notlar/notes"
    /// A source category whose extension is gone (removed or turned off): no descriptor.
    static let goneKey = "dev.example.gone/list"
    static let entries = [
        SourceRow(id: "1", title: "İş Portalı", subtitle: "deniz.k"),
        SourceRow(id: "2", title: "Kodhane", subtitle: "melike@ornek.dev"),
        SourceRow(id: "3", title: "ornek.dev", subtitle: "ops@ornek.dev"),
    ]

    let library: Library
    let sources: FakeSources
    let model: PanelViewModel
    let vault: ClipCategory
    let notes: ClipCategory
    let gone: ClipCategory

    /// History of two notes; three source categories (vault, notes, a gone one), all on select, so hidden at first.
    init() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        for (text, minutes) in [("toplantı notu", 1.0), ("ornek.dev şifre sıfırlama", 5.0)] {
            _ = try store.ingest(CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                              source: nil, device: .local, capturedAt: now.addingTimeInterval(-minutes * 60)))
        }
        library = try Library(store: store)
        try library.syncSourceCategories([SourceCategorySeed(key: Self.vaultKey, name: "Kasa"),
                                          SourceCategorySeed(key: Self.notesKey, name: "Notlar"),
                                          SourceCategorySeed(key: Self.goneKey, name: "Eski")])
        let categories = try store.categories()
        vault = try #require(categories.first { $0.source == Self.vaultKey })
        notes = try #require(categories.first { $0.source == Self.notesKey })
        gone = try #require(categories.first { $0.source == Self.goneKey })
        let language = LanguageStore(defaults: TestScratch.defaults("yab-src"), preferredLanguages: ["en"])
        language.language = .turkish
        sources = FakeSources()
        sources.descriptors = [FakeSources.vault(), FakeSources.vault(extensionID: "dev.example.notlar", sourceID: "notes", title: "Notlar")]
        sources.states[Self.vaultKey] = .rows(Self.entries)
        model = PanelViewModel(library: library, language: language, sources: sources, now: { now })
        library.onChange = { [model] in model.refresh() }
        model.reset()
    }

    var vaultColumn: PanelColumn? { model.columns.first { $0.sourceKey == Self.vaultKey } }
    var vaultTitles: [String] { vaultColumn?.rows.map(\.title) ?? [] }
    var historyTitles: [String] { model.columns.first { $0.id == .history }?.rows.map(\.title) ?? [] }

    @Test func aSourceColumnShowsItsRowsWithoutTouchingHistory() throws {
        let history = historyTitles
        let total = library.index.search("", limit: 100).total
        model.toggleShown(vault.id!)
        let column = try #require(vaultColumn)
        #expect(column.id == .category(vault.id!))
        #expect(column.title == "Kasa")
        #expect(model.focusedSource == .category(vault.id!))
        #expect(column.rows.map(\.title) == ["İş Portalı", "Kodhane", "ornek.dev"])
        #expect(column.rows.map(\.source) == Self.entries.map { .entry(key: Self.vaultKey, row: $0) })
        #expect(column.rows.allSatisfy { $0.id <= RowModel.sourceIDBase })
        #expect(column.emptyMessage == nil)
        // History, its index and the category's items are as they were.
        #expect(historyTitles == history)
        #expect(library.index.search("", limit: 100).total == total)
        #expect(library.index.search("Portal", limit: 100).total == 0)
        #expect(library.itemIDs(inCategory: vault.id!).isEmpty)
    }

    @Test func searchMatchesTitleAndSubtitleWithTurkishFolding() throws {
        model.toggleShown(vault.id!)
        _ = model.handle(.type("is portali"))
        #expect(vaultTitles == ["İş Portalı"])
        #expect(model.selectedSourceRow == .entry(key: Self.vaultKey, row: Self.entries[0]))
        _ = model.handle(.escape)
        _ = model.handle(.type("deniz"))
        #expect(vaultTitles == ["İş Portalı"])
        _ = model.handle(.escape)
        _ = model.handle(.type("ornek.dev"))
        #expect(vaultTitles == ["Kodhane", "ornek.dev"])
        _ = model.handle(.escape)
        _ = model.handle(.type("xyz"))
        #expect(vaultTitles.isEmpty)
        #expect(vaultColumn?.emptyMessage == "“xyz” bu kategoride yok.")
    }

    @Test func theLockedRowStaysWhileSearching() throws {
        sources.states[Self.vaultKey] = .locked(message: "Kasa kilitli", command: "kasa login <e-posta>")
        model.toggleShown(vault.id!)
        let locked = SourceRowInfo.locked(key: Self.vaultKey, message: "Kasa kilitli", command: "kasa login <e-posta>")
        #expect(vaultColumn?.rows.map(\.source) == [locked])
        #expect(model.selectedSourceRow == locked)
        _ = model.handle(.type("xyz"))
        #expect(vaultColumn?.rows.map(\.source) == [locked])
        #expect(vaultColumn?.emptyMessage == nil)
        // The count reads what the column shows: its one row.
        #expect(vaultColumn?.total == 1)
        #expect(model.resultCountText == "1 sonuç")
    }

    @Test func aRefreshKeepsTheSelectedRow() throws {
        model.toggleShown(vault.id!)
        _ = model.handle(.move(1))
        let selected = try #require(model.selectedID)
        #expect(model.selectedSourceRow == .entry(key: Self.vaultKey, row: Self.entries[1]))
        // The new list comes in another order, with the selected entry renamed.
        let renamed = SourceRow(id: "2", title: "Kodhane (iş)", subtitle: "melike@ornek.dev")
        sources.answer(Self.vaultKey, .rows([Self.entries[2], renamed, SourceRow(id: "4", title: "Eskiz", subtitle: nil), Self.entries[0]]))
        #expect(vaultTitles == ["ornek.dev", "Kodhane (iş)", "Eskiz", "İş Portalı"])
        #expect(model.selectedID == selected)
        #expect(model.selectedSourceRow == .entry(key: Self.vaultKey, row: renamed))
        #expect(model.focusedSource == .category(vault.id!))
    }

    @Test func openingThePanelRefreshesOnlyVisibleSources() {
        model.toggleShown(vault.id!)
        model.toggleShown(gone.id!)
        sources.refreshed = []
        model.reset()
        #expect(sources.refreshed == [[Self.vaultKey]])
    }

    @Test func showingASourceColumnRefreshesIt() {
        // No source column was open when the panel opened.
        #expect(sources.refreshed.isEmpty)
        model.toggleShown(notes.id!)
        #expect(sources.refreshed == [[Self.notesKey]])
        // Hiding it asks nothing.
        model.toggleShown(notes.id!)
        #expect(sources.refreshed == [[Self.notesKey]])
    }

    @Test func sourceRowsAreNotItems() throws {
        model.toggleShown(vault.id!)
        #expect(model.selectedID != nil)
        #expect(model.selectedItemID == nil)
        #expect(model.handle(.delete) == nil)
        #expect(vaultTitles == ["İş Portalı", "Kodhane", "ornek.dev"])
        #expect(model.handle(.togglePin) == nil)
        #expect(model.layer == .none)
        #expect(model.shiftReturnAction == nil)
    }

    @Test func aLoadingSourceSaysSo() throws {
        sources.states[Self.notesKey] = nil
        model.toggleShown(notes.id!)
        let idle = try #require(model.columns.first { $0.sourceKey == Self.notesKey })
        #expect(idle.rows.isEmpty)
        #expect(idle.emptyMessage == "Yükleniyor…")
        sources.answer(Self.notesKey, .loading)
        #expect(model.columns.first { $0.sourceKey == Self.notesKey }?.emptyMessage == "Yükleniyor…")
        sources.answer(Self.notesKey, .rows([SourceRow(id: "a", title: "Alışveriş", subtitle: nil)]))
        #expect(model.columns.first { $0.sourceKey == Self.notesKey }?.rows.map(\.title) == ["Alışveriş"])
    }

    /// The service's reason is for developers, in English; the column says it calmly, in the app's language.
    @Test func aFailedSourceShowsACalmLine() throws {
        sources.states[Self.vaultKey] = .failed(ExtensionError(.script, "vault-cli exited with status 1"))
        model.toggleShown(vault.id!)
        let column = try #require(vaultColumn)
        #expect(column.rows.isEmpty)
        #expect(column.emptyMessage == "Liste okunamadı.")
    }

    /// A tool that is not installed is named, in the words a job's card uses; the install line stays for developers.
    @Test func aMissingToolIsNamed() throws {
        sources.states[Self.vaultKey] = .failed(ExtensionError(.toolMissing, "vault-cli is not installed. Install it with: brew install vault-cli"))
        model.toggleShown(vault.id!)
        #expect(vaultColumn?.rows.isEmpty == true)
        #expect(vaultColumn?.emptyMessage == "vault-cli bulunamadı")
        // One whose reason names no tool reads like any other failure.
        sources.answer(Self.vaultKey, .failed(ExtensionError(.toolMissing, "")))
        #expect(vaultColumn?.emptyMessage == "Liste okunamadı.")
    }

    @Test func aDisabledExtensionsColumnIsHidden() {
        model.toggleShown(gone.id!)
        #expect(!model.columns.contains { $0.id == .category(gone.id!) })
        #expect(!sources.refreshed.joined().contains(Self.goneKey))
        model.reset()
        #expect(!sources.refreshed.joined().contains(Self.goneKey))
    }

    /// A panel without sources (none wired) shows no source column.
    @Test func noSourcesNoSourceColumns() throws {
        let language = LanguageStore(defaults: TestScratch.defaults("yab-src"), preferredLanguages: ["en"])
        let bare = PanelViewModel(library: library, language: language, now: { now })
        bare.reset()
        bare.toggleShown(vault.id!)
        #expect(bare.columns.map(\.id) == [.history])
    }

    @Test func rowIdsStayPutPerSourceAndRow() {
        let identity = SourceRowIdentity()
        let first = identity.id(key: Self.vaultKey, row: "1")
        #expect(first <= RowModel.sourceIDBase)
        #expect(identity.id(key: Self.notesKey, row: "1") != first)
        #expect(identity.id(key: Self.vaultKey, row: "2") != first)
        #expect(identity.id(key: Self.vaultKey, row: "1") == first)
        let locked = identity.lockedID(key: Self.vaultKey)
        #expect(locked != first && locked != identity.id(key: Self.vaultKey, row: "2"))
        #expect(identity.lockedID(key: Self.vaultKey) == locked)
        #expect(identity.lockedID(key: Self.notesKey) != locked)
    }
}
