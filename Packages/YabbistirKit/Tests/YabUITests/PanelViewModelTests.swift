import Foundation
import Testing
@testable import YabCore
import YabLocalization
import YabPasteboard
import YabStack
@testable import YabUI

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

private func clip(_ s: String, minutesAgo: Double) -> CapturedClip {
    CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(s.utf8))]],
                 source: nil, device: .local, capturedAt: now.addingTimeInterval(-minutesAgo * 60))
}

@MainActor @Suite struct PanelViewModelTests {
    let library: Library
    let language: LanguageStore
    let model: PanelViewModel
    let code: ClipCategory
    let links: ClipCategory

    /// History of six items; "Kod" (always shown) holds the SQL lines, "Bağlantılar" (on select) one item.
    init() throws {
        let store = try ItemStore.temporary()
        let samples: [(String, Double)] = [
            ("SELECT id FROM users", 0.5), ("UPDATE users SET status", 1), ("İade akışı demosu", 60),
            ("selam dünya", 1560), ("haftalık rapor", 4320), ("eski not", 57600),
        ]
        var ids: [String: Int64] = [:]
        for (text, minutes) in samples {
            ids[text] = try #require(try store.ingest(clip(text, minutesAgo: minutes))).item.id
        }
        code = try store.createCategory(name: "Kod", color: .slate, visibility: .always)
        links = try store.createCategory(name: "Bağlantılar", color: .sage)
        try store.add(itemID: ids["UPDATE users SET status"]!, toCategory: code.id!)
        try store.add(itemID: ids["SELECT id FROM users"]!, toCategory: code.id!)
        try store.add(itemID: ids["İade akışı demosu"]!, toCategory: links.id!)
        library = try Library(store: store)
        language = LanguageStore(defaults: UserDefaults(suiteName: "yab-ui-\(UUID().uuidString)")!)
        language.language = .turkish
        model = PanelViewModel(library: library, language: language, now: { now })
        library.onChange = { [model] in model.refresh() }
        model.reset()
    }

    var allRows: [RowModel] { model.columns[0].rows }

    @Test func typingFiltersAndSelectsFirst() {
        _ = model.handle(.type("iade"))
        #expect(allRows.map(\.title) == ["İade akışı demosu"])
        #expect(model.selectedID == allRows.first?.id)
    }

    @Test func moveClampsWithinResults() {
        _ = model.handle(.move(-1))
        #expect(model.selectedID == allRows.first?.id)
        _ = model.handle(.move(99))
        #expect(model.selectedID == allRows.last?.id)
    }

    @Test func confirmReturnsPasteOfSelected() {
        let first = allRows.first!.id
        #expect(model.handle(.confirm(plain: false)) == .paste(itemID: first, plain: false))
    }

    @Test func shiftConfirmIsPlain() {
        let first = allRows.first!.id
        #expect(model.handle(.confirm(plain: true)) == .paste(itemID: first, plain: true))
    }

    @Test func escapeClearsQueryThenCloses() {
        _ = model.handle(.type("sel"))
        #expect(model.handle(.escape) == nil)
        #expect(model.query == "")
        #expect(model.handle(.escape) == .close)
    }

    @Test func sectionsGroupByDay() {
        #expect(model.sections.map(\.title) == ["Bugün", "Dün", "Bu hafta", "Daha eski"])
    }

    @Test func noResultsShowsLocalizedEmptyState() {
        _ = model.handle(.type("zzzq"))
        #expect(model.sections.isEmpty)
        #expect(model.emptyMessage == "“zzzq” için sonuç yok")
    }

    @Test func highlightFoldsTurkish() {
        _ = model.handle(.type("iade"))
        let row = allRows.first!
        #expect(PanelViewModel.highlights(in: row.title, query: model.query).map { String(row.title[$0]) } == ["İade"])
    }

    @Test func selectAllThenTypingReplacesTheQuery() {
        _ = model.handle(.type("sel"))
        _ = model.handle(.selectAll)
        #expect(model.isQuerySelected)
        _ = model.handle(.type("i"))
        #expect(model.query == "i")
        #expect(!model.isQuerySelected)
    }

    @Test func selectAllThenDeleteClearsTheQuery() {
        _ = model.handle(.type("sel"))
        _ = model.handle(.selectAll)
        _ = model.handle(.deleteBackward)
        #expect(model.query == "")
        #expect(!model.isQuerySelected)
    }

    @Test func hoverSelectionDoesNotScroll() {
        let before = model.scrollRequest
        model.select(allRows[2].id)
        #expect(model.selectedID == allRows[2].id)
        #expect(model.scrollRequest == before)
    }

    @Test func keyboardMoveScrollsToTheSelection() {
        model.select(allRows[2].id)
        _ = model.handle(.move(1))
        #expect(model.scrollRequest?.id == allRows[3].id)
    }

    @Test func columnsAreHistoryThenAlwaysCategoriesThenShownOnes() {
        #expect(model.columns.map(\.title) == ["Geçmiş", "Kod"])
        model.toggleShown(links.id!)
        #expect(model.columns.map(\.title) == ["Geçmiş", "Kod", "Bağlantılar"])
        #expect(model.focusedColumn == 2)
    }

    @Test func moveColumnClampsAndNudgesAtTheEdge() {
        _ = model.handle(.moveColumn(1))
        #expect(model.focusedColumn == 1)
        _ = model.handle(.moveColumn(1))
        #expect(model.focusedColumn == 1)
        #expect(model.edgeNudge == 1)
    }

    @Test func eachColumnRemembersItsSelection() {
        _ = model.handle(.move(1))
        let historySelection = model.selectedID
        _ = model.handle(.moveColumn(1))
        _ = model.handle(.moveColumn(-1))
        #expect(model.selectedID == historySelection)
    }

    @Test func commandDigitPastesTheNthRowOfTheFocusedColumn() {
        _ = model.handle(.moveColumn(1))
        let second = model.columns[1].sections.flatMap(\.rows)[1].id
        #expect(model.handle(.pasteIndex(2)) == .paste(itemID: second, plain: false))
        #expect(model.handle(.pasteIndex(9)) == nil)
    }

    @Test func deleteInACategoryOnlyRemovesTheMembership() throws {
        _ = model.handle(.moveColumn(1))
        let id = try #require(model.selectedID)
        _ = model.handle(.delete)
        #expect(try library.store.item(id: id) != nil)
        #expect(!model.columns[1].sections.flatMap(\.rows).map(\.id).contains(id))
    }

    @Test func searchFiltersEveryColumnAndCountsTheFocusedOne() {
        _ = model.handle(.type("select"))
        #expect(model.columns[0].total == 1)
        #expect(model.columns[1].total == 1)
    }

    @Test func escapeClosesTheLayerBeforeClearingTheSearch() {
        _ = model.handle(.type("x"))
        _ = model.handle(.toggleActions)
        #expect(model.handle(.escape) == nil)
        #expect(model.layer == .none)
        #expect(model.query == "x")
    }

    @Test func spaceTogglesPreviewOnlyWithAnEmptyQuery() {
        _ = model.handle(.togglePreview)
        #expect(model.isPreviewVisible)
        _ = model.handle(.type("a"))
        _ = model.handle(.togglePreview)
        #expect(model.query == "a ")
    }

    @Test func deletingTheFocusedCategoryClampsFocus() throws {
        _ = model.handle(.moveColumn(1))
        try library.deleteCategory(id: code.id!)
        #expect(model.focusedColumn == 0)
    }

    @Test func indexKeysAppearAfter200msOfHoldingCommand() async throws {
        let start = ContinuousClock.now
        _ = model.handle(.commandHeld(true))
        #expect(!model.showsIndexKeys)
        // Polled, not slept: parallel suites can keep the main actor busy for seconds. Main-actor
        // jobs run in order, so a poll queued before the hold task's wake-up can see the deadline
        // pass first; a few polls past it let the queued wake-up run.
        var pollsPastDeadline = 0
        while !model.showsIndexKeys, pollsPastDeadline < 5 {
            if ContinuousClock.now - start >= .seconds(5) { pollsPastDeadline += 1 }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.showsIndexKeys)
        #expect(ContinuousClock.now - start >= .milliseconds(200))
        _ = model.handle(.commandHeld(false))
        #expect(!model.showsIndexKeys)
    }

    @Test func aShortcutDuringTheHoldCancelsIndexKeys() async throws {
        _ = model.handle(.commandHeld(true))
        _ = model.handle(.copy)
        try await Task.sleep(for: .milliseconds(260))
        #expect(!model.showsIndexKeys)
    }

    @Test func hoverInAnotherColumnFocusesItWithoutScrolling() {
        let request = model.scrollRequest
        let target = model.columns[1].rows[1].id
        model.select(target, in: .category(code.id!))
        #expect(model.focusedColumn == 1)
        #expect(model.selectedID == target)
        #expect(model.scrollRequest == request)
    }

    @Test func focusPastTheVisibleColumnsScrollsTheStrip() {
        model.availableWidth = 2 * ColumnStripLayout.columnWidth + 20
        model.toggleShown(links.id!)
        #expect(model.visibleColumnCount == 2)
        #expect(model.sheetWidth == 2 * ColumnStripLayout.columnWidth)
        #expect(model.firstVisibleColumn == 1)
        _ = model.handle(.moveColumn(-1))
        _ = model.handle(.moveColumn(-1))
        #expect(model.firstVisibleColumn == 0)
    }

    @Test func categoryMenuListsOnSelectCategoriesThenEdit() {
        _ = model.handle(.toggleCategoryMenu)
        #expect(model.layer == .categoryMenu)
        #expect(model.categoryMenu == [.category(links, isShown: false), .editCategories])
    }
    @Test func confirmTogglesAColumnAndKeepsTheMenuOpen() {
        _ = model.handle(.toggleCategoryMenu)
        _ = model.handle(.confirm(plain: false))
        #expect(model.columns.map(\.title).last == "Bağlantılar")
        #expect(model.layer == .categoryMenu)
    }
    @Test func editRowOpensTheEditor() {
        _ = model.handle(.toggleCategoryMenu)
        _ = model.handle(.move(1))
        #expect(model.handle(.confirm(plain: false)) == .openEditor)
    }
    @Test func spaceAlsoTogglesAndTypingIsIgnoredInTheMenu() {
        _ = model.handle(.toggleCategoryMenu)
        _ = model.handle(.type("x"))
        #expect(model.query == "")
        _ = model.handle(.togglePreview)
        #expect(model.categoryMenu.first == .category(links, isShown: true))
        #expect(!model.isPreviewVisible)
    }

    @Test func typingInActionsFiltersActionsNotHistory() {
        _ = model.handle(.toggleActions)
        _ = model.handle(.type("kop"))
        #expect(model.query == "")
        #expect(model.actionItems == [.copy])
    }
    @Test func runningCopyFromActionsReturnsCopy() {
        let id = model.selectedID!
        _ = model.handle(.toggleActions)
        _ = model.handle(.type("kop"))
        #expect(model.handle(.confirm(plain: false)) == .copy(itemID: id))
        #expect(model.layer == .none)
    }
    @Test func deleteReadsRemoveInsideACategory() {
        _ = model.handle(.moveColumn(1))
        _ = model.handle(.toggleActions)
        #expect(model.actionLabel(.delete) == "Kategoriden çıkar")
    }
    @Test func addToCategoryFromActionsOpensThePinLayer() {
        _ = model.handle(.toggleActions)
        _ = model.handle(.type("kategori"))
        #expect(model.actionItems == [.addToCategory, .editCategories])
        _ = model.handle(.confirm(plain: false))
        #expect(model.layer == .pin)
    }

    @Test func pinListsCategoriesWithMembership() {
        _ = model.handle(.togglePin)
        #expect(model.layer == .pin)
        #expect(model.pinOptions.contains(.category(links, isMember: false)))
    }
    @Test func pinOffersCreateOnlyForANewTrimmedName() {
        _ = model.handle(.togglePin)
        _ = model.handle(.type("  "))
        #expect(!model.pinOptions.contains { if case .create = $0 { true } else { false } })
        _ = model.handle(.deleteBackward); _ = model.handle(.deleteBackward)
        _ = model.handle(.type("KOD"))
        #expect(!model.pinOptions.contains(.create(name: "KOD")))
    }
    @Test func creatingFromPinAddsTheItemAndOpensTheColumn() throws {
        let id = model.selectedID!
        _ = model.handle(.togglePin)
        _ = model.handle(.type("Sunum"))
        _ = model.handle(.confirm(plain: false))
        let created = try #require(try library.store.categories().first { $0.name == "Sunum" })
        #expect(created.visibility == .onSelect)
        #expect(try library.store.itemIDs(inCategory: created.id!) == [id])
        #expect(model.columns.map(\.title).contains("Sunum"))
    }

    @Test func firstArrowKeyTurnsOnKeyboardPreview() {
        #expect(model.previewSource == nil)
        _ = model.handle(.move(1))
        #expect(model.previewSource == .keyboard)
    }
    @Test func hoverNeverDowngradesKeyboardPreview() {
        _ = model.handle(.move(1))
        model.hoverIntent(model.selectedID!)
        #expect(model.previewSource == .keyboard)
    }
    @Test func spaceMutesAndPanelResetClears() {
        _ = model.handle(.move(1))
        _ = model.handle(.togglePreview)
        #expect(model.previewMuted)
        model.reset()
        #expect(model.previewSource == nil && !model.previewMuted)
    }

    @Test func commandDeleteInPinClearsTheSearchAndKeepsTheItem() throws {
        let id = try #require(model.selectedID)
        _ = model.handle(.togglePin)
        _ = model.handle(.type("Sun"))
        _ = model.handle(.delete)
        #expect(model.pinQuery == "")
        #expect(model.layer == .pin)
        #expect(try library.store.item(id: id) != nil)
        #expect(model.columns[0].rows.contains { $0.id == id })
    }

    @Test func panelKeysDoNotChangeTheItemUnderAnOpenLayer() {
        let id = model.selectedID
        for layer in [PanelCommand.togglePin, .toggleActions, .toggleCategoryMenu] {
            _ = model.handle(layer)
            #expect(model.handle(.moveColumn(1)) == nil)
            #expect(model.handle(.pasteIndex(2)) == nil)
            #expect(model.handle(.copy) == nil)
            #expect(model.focusedColumn == 0)
            #expect(model.selectedID == id)
            _ = model.handle(.escape)
        }
    }

    @Test func aNewQueryAfterMovingSelectsTheFirstMatch() {
        _ = model.handle(.move(2))
        _ = model.handle(.type("sel"))
        #expect(model.selectedID == model.columns[0].rows.first?.id)
    }
}

@MainActor @Suite struct PanelTypingPerformanceTests {
    @Test func keystrokeOverLongRowsFitsInAFrame() throws {
        let store = try ItemStore.temporary()
        let paragraph = String(repeating: "ölçüm değeri e ", count: 1_400)
        for minute in 0..<200 {
            _ = try store.ingest(clip("\(minute) \(paragraph)", minutesAgo: Double(minute)))
        }
        let library = try Library(store: store)
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-perf-\(UUID().uuidString)")!)
        let model = PanelViewModel(library: library, language: language, now: { now })
        model.reset()
        _ = model.handle(.type("x"))
        _ = model.handle(.deleteBackward)
        let elapsed = ContinuousClock().measure { _ = model.handle(.type("e")) }
        #expect(model.sections.flatMap(\.rows).count == 200)
        #expect(elapsed < .milliseconds(16))
    }
}

/// A keystroke stays within 16 ms at 20,000 items, here with six category columns.
@MainActor @Suite struct PanelCategoryPerformanceTests {
    @Test func keystrokeWithSixCategoryColumnsFitsInAFrame() throws {
        let store = try ItemStore.temporary()
        try store.insertSyntheticItems(count: 20_000, now: now)
        let library = try Library(store: store)
        let ids = library.index.search("", limit: 20_000).ids
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-perf-cat-\(UUID().uuidString)")!)
        let model = PanelViewModel(library: library, language: language, now: { now })
        for (offset, name) in ["A", "B", "C", "D", "E", "F"].enumerated() {
            let category = try library.createCategory(name: name)
            for id in ids.dropFirst(offset * 400).prefix(400) { try store.add(itemID: id, toCategory: category.id!) }
            model.toggleShown(category.id!)
        }
        model.reset()
        _ = model.handle(.type("x"))
        _ = model.handle(.deleteBackward)
        let elapsed = ContinuousClock().measure { _ = model.handle(.type("e")) }
        #expect(model.columns.count == 7)
        #expect(elapsed < .milliseconds(16), "\(elapsed)")
    }
}

private final class StackWriter: PasteboardWriting {
    func write(_ items: [[PasteboardRepresentation]], plainTextOnly: Bool) -> Int { 0 }
}

/// The panel with the Sıra open: "UPDATE…" then "SELECT…" are queued.
@MainActor @Suite struct PanelStackTests {
    let library: Library
    let model: PanelViewModel
    let stack: StackSession

    init() throws {
        let store = try ItemStore.temporary()
        var ids: [String: Int64] = [:]
        for (text, minutes) in [("SELECT id FROM users", 0.5), ("UPDATE users SET status", 1.0), ("İade akışı demosu", 60.0)] {
            ids[text] = try #require(try store.ingest(clip(text, minutesAgo: minutes))).item.id
        }
        let code = try store.createCategory(name: "Kod", color: .slate, visibility: .always)
        try store.add(itemID: ids["SELECT id FROM users"]!, toCategory: code.id!)
        library = try Library(store: store)
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-ui-\(UUID().uuidString)")!)
        language.language = .turkish
        stack = StackSession(library: library, writer: StackWriter(), didWrite: { _ in })
        stack.append(ids["UPDATE users SET status"]!)
        stack.append(ids["SELECT id FROM users"]!)
        model = PanelViewModel(library: library, language: language, stack: stack, now: { now })
        library.onChange = { [model] in model.refresh() }
        model.reset()
    }

    @Test func theStackColumnSitsLeftOfHistoryWhichKeepsFocus() {
        #expect(model.columns.map(\.title) == ["Sıra", "Geçmiş", "Kod"])
        #expect(model.focusedColumn == 1)
        #expect(model.columns[0].rows.map(\.stackNumber) == [1, 2])
    }

    @Test func optionArrowsReorderTheStack() {
        _ = model.handle(.moveColumn(-1))
        let first = stack.entries[0].id
        _ = model.handle(.moveItem(1))
        #expect(stack.entries[1].id == first)
        #expect(model.selectedID == -Int64(first))
    }

    @Test func commandDeleteOnlyLeavesTheStack() throws {
        _ = model.handle(.moveColumn(-1))
        let item = try #require(model.selectedItemID)
        _ = model.handle(.delete)
        #expect(stack.entries.count == 1)
        #expect(try library.store.item(id: item) != nil)
    }

    @Test func returnPastesAStackItemOutOfOrder() {
        _ = model.handle(.moveColumn(-1))
        _ = model.handle(.move(1))
        let entry = stack.entries[1]
        #expect(model.handle(.confirm(plain: false)) == .pasteFromStack(entryID: entry.id, itemID: entry.itemID, plain: false))
    }

    @Test func addToStackFromActions() {
        let item = model.selectedItemID!
        _ = model.handle(.toggleActions)
        _ = model.handle(.type("sıraya"))
        #expect(model.actionItems == [.addToStack])
        #expect(model.handle(.confirm(plain: false)) == .addToStack(itemID: item))
    }

    /// Deleting a queued item from History drops its stack entry too ("UPDATE…" is in no
    /// category, so ⌘⌫ deletes it).
    @Test func deletingAQueuedItemFromHistoryDropsItsEntry() {
        _ = model.handle(.move(1))
        let item = stack.entries[0].itemID
        #expect(model.selectedItemID == item)
        _ = model.handle(.delete)
        #expect(stack.entries.map(\.itemID).contains(item) == false)
        #expect(model.columns[0].rows.count == 1)
    }

    @Test func theStackColumnLeavesWhenTheStackCloses() {
        stack.finish()
        model.refresh()
        #expect(model.columns.map(\.title) == ["Geçmiş", "Kod"])
        #expect(model.focusedColumn == 0)
    }
}

