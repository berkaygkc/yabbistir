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

/// A source's row (a synthetic vault's entry) is no item: its keys run the source's own actions. ↵ and ⌘1–9 paste the
/// password, ⇧↵ the username, ⌘C copies the username and never the password; the locked row copies its command.
@MainActor @Suite struct SourceActionsTests {
    static let vaultKey = "dev.example.kasa/vault"
    /// A source with one secret action and nothing to copy.
    static let pinKey = "dev.example.pin/codes"
    static let entries = [
        SourceRow(id: "1", title: "İş Portalı", subtitle: "deniz.k"),
        SourceRow(id: "2", title: "Kodhane", subtitle: "melike@ornek.dev"),
        SourceRow(id: "3", title: "ornek.dev", subtitle: "ops@ornek.dev"),
    ]
    static let pinOnly = SourceDescriptor(extensionID: "dev.example.pin", extensionName: "PIN", sourceID: "codes", title: "PIN",
                                          sensitive: true, actions: [
                                              SourceActionDescriptor(id: "pin", kind: .secret, title: "PIN’i yapıştır", label: "PIN"),
                                          ])

    let library: Library
    let sources: FakeSources
    let model: PanelViewModel
    let vault: ClipCategory
    let pins: ClipCategory

    /// History of one note; the vault's column and a one-action source's, both shown, the vault's focused.
    init() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.ingest(CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("toplantı notu".utf8))]],
                                          source: nil, device: .local, capturedAt: now.addingTimeInterval(-60)))
        library = try Library(store: store)
        try library.syncSourceCategories([SourceCategorySeed(key: Self.vaultKey, name: "Kasa"), SourceCategorySeed(key: Self.pinKey, name: "PIN")])
        let categories = try store.categories()
        vault = try #require(categories.first { $0.source == Self.vaultKey })
        pins = try #require(categories.first { $0.source == Self.pinKey })
        let language = LanguageStore(defaults: TestScratch.defaults("yab-src-act"), preferredLanguages: ["en"])
        language.language = .turkish
        sources = FakeSources()
        sources.descriptors = [FakeSources.vault(), Self.pinOnly]
        sources.states[Self.vaultKey] = .rows(Self.entries)
        sources.states[Self.pinKey] = .rows([SourceRow(id: "p1", title: "Banka", subtitle: nil)])
        model = PanelViewModel(library: library, language: language, sources: sources, now: { now }, shiftHintDelay: .zero)
        model.reset()
        model.toggleShown(pins.id!)
        model.toggleShown(vault.id!)
    }

    func run(_ row: String, _ action: String, copy: Bool = false, key: String = Self.vaultKey) -> PanelAction {
        .runSource(key: key, row: row, action: action, copy: copy)
    }

    func focusPins() throws {
        model.select(try #require(model.columns.first { $0.sourceKey == Self.pinKey }?.rows.first?.id), in: .category(pins.id!))
    }

    func focusVault() throws {
        model.select(try #require(model.columns.first { $0.sourceKey == Self.vaultKey }?.rows.first?.id), in: .category(vault.id!))
    }

    func lock(command: String?) {
        sources.answer(Self.vaultKey, .locked(message: "Kasa kilitli", command: command))
    }

    @Test func returnRunsThePrimaryAction() {
        #expect(model.focusedSource == .category(vault.id!))
        #expect(model.handle(.confirm(plain: false)) == run("1", "password"))
        _ = model.handle(.move(1))
        #expect(model.handle(.confirm(plain: false)) == run("2", "password"))
        // A double click or the bar's button: the same.
        #expect(model.pasteAction(rowID: model.selectedID!, plain: false) == run("2", "password"))
    }

    @Test func shiftReturnRunsTheAlternate() throws {
        #expect(model.handle(.confirm(plain: true)) == run("1", "username"))
        // One action only: ⇧↵ runs it, as ↵ does.
        try focusPins()
        #expect(model.handle(.confirm(plain: true)) == run("p1", "pin", key: Self.pinKey))
    }

    @Test func commandDigitsRunThePrimary() {
        #expect(model.handle(.pasteIndex(3)) == run("3", "password"))
        #expect(model.selectedSourceRow == .entry(key: Self.vaultKey, row: Self.entries[2]))
        #expect(model.handle(.pasteIndex(4)) == nil)
    }

    /// ⌘C copies the text action (the username); a source whose only action is a secret has nothing to copy.
    @Test func commandCCopiesTheTextActionNeverTheSecret() throws {
        #expect(model.handle(.copy) == run("1", "username", copy: true))
        try focusPins()
        #expect(model.handle(.copy) == nil)
        // Nor does ⌘K or the ⇧ panel offer a copy there.
        _ = model.handle(.toggleActions)
        #expect(!model.actionItems.contains(.sourceCopy))
        _ = model.handle(.escape)
        _ = model.handle(.toggleTransforms)
        #expect(model.sourceListItems == [.sourcePrimary])
        #expect(model.handle(.copy) == nil)
        #expect(model.layer == .transforms)
    }

    @Test func deleteAndPinDoNothingOnASourceRow() {
        #expect(model.handle(.delete) == nil)
        #expect(model.columns.first { $0.sourceKey == Self.vaultKey }?.rows.map(\.title) == Self.entries.map(\.title))
        #expect(model.handle(.togglePin) == nil)
        #expect(model.layer == .none)
    }

    /// A ⇧ tap lists the row's actions, each with its key: ↵ runs the highlighted one, ⇧↵ and ⌘C work as on the row.
    @Test func shiftTapListsTheSourceActions() {
        _ = model.handle(.move(1))
        _ = model.handle(.toggleTransforms)
        #expect(model.layer == .transforms)
        #expect(model.transformSource?.row == Self.entries[1])
        #expect(model.transformSource?.descriptor == FakeSources.vault())
        #expect(model.sourceListItems == [.sourcePrimary, .sourceAlternate, .sourceCopy])
        #expect(model.sourceListItems.map(model.actionLabel) == ["Şifreyi yapıştır", "Kullanıcı adını yapıştır", "Kullanıcı adını kopyala"])
        #expect(model.sourceListConfirmLabel == "Yapıştır")
        // Nothing to search, no menu of its own.
        _ = model.handle(.type("g"))
        _ = model.handle(.toggleActions)
        #expect(!model.transformMenuOpen)
        #expect(model.transformQuery.isEmpty)
        #expect(model.layer == .transforms)
        _ = model.handle(.move(2))
        #expect(model.sourceListConfirmLabel == "Kopyala")
        #expect(model.handle(.confirm(plain: false)) == run("2", "username", copy: true))
        #expect(model.layer == .none)
        #expect(model.transformSource == nil)

        _ = model.handle(.toggleTransforms)
        #expect(model.menuSelection == 0)
        #expect(model.handle(.confirm(plain: true)) == run("2", "username"))
        _ = model.handle(.toggleTransforms)
        #expect(model.handle(.copy) == run("2", "username", copy: true))
        _ = model.handle(.toggleTransforms)
        _ = model.handle(.move(1))
        #expect(model.activateMenuRow(0) == run("2", "password"))
        // ← closes it, as Esc and a second ⇧ tap do.
        _ = model.handle(.toggleTransforms)
        _ = model.handle(.moveColumn(-1))
        #expect(model.layer == .none)
        #expect(model.focusedSource == .category(vault.id!))
    }

    /// The locked row has nothing to list: the ⇧ tap nudges.
    @Test func theLockedRowHasNoShiftList() {
        lock(command: "kasa login <e-posta>")
        let nudges = model.edgeNudge
        _ = model.handle(.toggleTransforms)
        #expect(model.layer == .none)
        #expect(model.edgeNudge == nudges + 1)
    }

    @Test func commandKListsTheSourceActions() {
        _ = model.handle(.toggleActions)
        #expect(model.actionItems == [.sourcePrimary, .sourceAlternate, .sourceCopy, .preview, .editCategories])
        #expect(model.actionItems.map(model.actionLabel)
            == ["Şifreyi yapıştır", "Kullanıcı adını yapıştır", "Kullanıcı adını kopyala", "Önizle", "Kategorileri düzenle"])
        #expect(model.sourceAction(.sourcePrimary)?.kind == .secret)
        #expect(model.sourceAction(.sourceAlternate)?.kind == .text)
        _ = model.handle(.move(1))
        #expect(model.handle(.confirm(plain: false)) == run("1", "username"))
        _ = model.handle(.toggleActions)
        _ = model.handle(.move(2))
        #expect(model.handle(.confirm(plain: false)) == run("1", "username", copy: true))
        // A search finds them by their words.
        _ = model.handle(.toggleActions)
        for character in "kopy" { _ = model.handle(.type(String(character))) }
        #expect(model.actionItems == [.sourceCopy])
        _ = model.handle(.escape)
        // The locked row: its command, then the editor; nothing to preview.
        lock(command: "kasa login <e-posta>")
        _ = model.handle(.toggleActions)
        #expect(model.actionItems == [.copySourceCommand, .editCategories])
        #expect(model.actionLabel(.copySourceCommand) == "Komutu kopyala")
        #expect(model.handle(.confirm(plain: false)) == .copySourceCommand("kasa login <e-posta>"))
        lock(command: nil)
        _ = model.handle(.toggleActions)
        #expect(model.actionItems == [.editCategories])
    }

    @Test func theLockedRowCopiesItsCommand() {
        lock(command: "kasa login <e-posta>")
        #expect(model.handle(.confirm(plain: false)) == .copySourceCommand("kasa login <e-posta>"))
        #expect(model.handle(.copy) == .copySourceCommand("kasa login <e-posta>"))
        #expect(model.handle(.confirm(plain: true)) == .copySourceCommand("kasa login <e-posta>"))
        lock(command: nil)
        #expect(model.handle(.confirm(plain: false)) == nil)
        #expect(model.handle(.copy) == nil)
    }

    @Test func theBarNamesTheSourceActions() throws {
        #expect(model.sourceBar == SourceBar(primary: BarLabel(title: "Şifreyi yapıştır", keys: ["↵"]),
                                             alternate: BarLabel(title: "Kullanıcı adı", keys: ["⇧", "↵"])))
        #expect(model.sourceCommandHints == [BarLabel(title: "Şifreyi yapıştır", keys: ["⌘", "1–9"]),
                                             BarLabel(title: "Kullanıcı adını kopyala", keys: ["⌘", "C"]),
                                             BarLabel(title: "Eylemler", keys: ["⌘", "K"])])
        try focusPins()
        #expect(model.sourceBar == SourceBar(primary: BarLabel(title: "PIN’i yapıştır", keys: ["↵"]), alternate: nil))
        #expect(model.sourceCommandHints == [BarLabel(title: "PIN’i yapıştır", keys: ["⌘", "1–9"]), BarLabel(title: "Eylemler", keys: ["⌘", "K"])])
        // The locked row: its command, ⌘C, alone (⌘K still opens its list, and its ⌘ hint says so).
        try focusVault()
        lock(command: "kasa login <e-posta>")
        #expect(model.sourceBar == SourceBar(primary: BarLabel(title: "Komutu kopyala", keys: ["⌘", "C"]), alternate: nil, showsActions: false))
        #expect(model.sourceCommandHints == [BarLabel(title: "Komutu kopyala", keys: ["⌘", "C"]), BarLabel(title: "Eylemler", keys: ["⌘", "K"])])
        // Without a command the bar is not left empty: "Eylemler ⌘K".
        lock(command: nil)
        #expect(model.sourceBar == SourceBar(primary: nil, alternate: nil))
        #expect(model.sourceBar?.showsActions == true)
        #expect(model.sourceCommandHints == [BarLabel(title: "Eylemler", keys: ["⌘", "K"])])
        // An item's row keeps the bar it had.
        _ = model.handle(.moveColumn(-1))
        _ = model.handle(.moveColumn(-1))
        #expect(model.focusedSource == .history)
        #expect(model.sourceBar == nil)
        #expect(model.sourceCommandHints == nil)
    }

    /// The source answered locked while the ⇧ list was open: the list goes with its row.
    @Test func aLockedAnswerClosesTheSourceList() {
        _ = model.handle(.move(1))
        _ = model.handle(.toggleTransforms)
        #expect(model.transformSource?.row == Self.entries[1])
        lock(command: "kasa login <e-posta>")
        #expect(model.layer == .none)
        #expect(model.transformSource == nil)
        // Forgotten (the Mac locked): the same.
        sources.answer(Self.vaultKey, .rows(Self.entries))
        _ = model.handle(.toggleTransforms)
        #expect(model.layer == .transforms)
        sources.answer(Self.vaultKey, .idle)
        #expect(model.layer == .none)
    }

    /// A new list without the row closes its ⇧ list; one that still has it (reordered, renamed) leaves it open.
    @Test func aRowThatLeavesClosesTheSourceList() {
        _ = model.handle(.move(1))
        _ = model.handle(.toggleTransforms)
        let renamed = SourceRow(id: "2", title: "Kodhane (iş)", subtitle: "melike@ornek.dev")
        sources.answer(Self.vaultKey, .rows([Self.entries[2], renamed, Self.entries[0]]))
        #expect(model.layer == .transforms)
        #expect(model.transformSource?.row.id == "2")
        sources.answer(Self.vaultKey, .rows([Self.entries[0], Self.entries[2]]))
        #expect(model.layer == .none)
        #expect(model.transformSource == nil)
    }

    @Test func holdingShiftOnASourceRowNamesTheAlternate() throws {
        _ = model.handle(.shiftHeld(true))
        #expect(model.showsShiftHint)
        #expect(model.shiftHintLabel == "Kullanıcı adını yapıştır")
        _ = model.handle(.shiftHeld(false))
        // ⇧↵ on a one-action source runs what ↵ runs: nothing to say.
        try focusPins()
        _ = model.handle(.shiftHeld(true))
        #expect(!model.showsShiftHint)
        _ = model.handle(.shiftHeld(false))
        // Nor on the locked row.
        lock(command: "kasa login <e-posta>")
        try focusVault()
        _ = model.handle(.shiftHeld(true))
        #expect(!model.showsShiftHint)
    }
}
