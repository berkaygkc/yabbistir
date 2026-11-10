import AppKit
import Foundation
import SwiftUI
import Testing
@testable import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
@testable import YabUI

/// The ⇧ panel's list against the screen: as tall as its rows while they fit (the panel unchanged), else what the
/// screen leaves, scrolling.
@Suite struct TransformListLayoutTests {
    @Test func everythingFitsUnchanged() {
        let fit = TransformListLayout.fit(rows: 5, sections: 2, available: 600)
        #expect(fit == TransformListLayout.Fit(height: 5 * 32 + 2 * 27, scrolls: false))
        #expect(fit.height == TransformListLayout.contentHeight(rows: 5, sections: 2))
    }

    @Test func exactlyFittingRowsDoNotScroll() {
        let content = TransformListLayout.contentHeight(rows: 12, sections: 3)
        #expect(TransformListLayout.fit(rows: 12, sections: 3, available: content) == .init(height: content, scrolls: false))
        #expect(TransformListLayout.fit(rows: 12, sections: 3, available: content - 0.5).scrolls)
    }

    @Test func moreRowsThanFitScrollInWhatIsLeft() {
        let fit = TransformListLayout.fit(rows: 60, sections: 14, available: 640.6)
        #expect(fit == .init(height: 640, scrolls: true))
    }

    @Test func theRowHeightIsAnInput() {
        #expect(TransformListLayout.fit(rows: 10, rowHeight: 40, available: 400) == .init(height: 400, scrolls: false))
        #expect(TransformListLayout.fit(rows: 10, rowHeight: 40, available: 399) == .init(height: 399, scrolls: true))
    }

    @Test func aTinyScreenStillShowsOneRow() {
        #expect(TransformListLayout.fit(rows: 30, available: 12) == .init(height: 32, scrolls: true))
        #expect(TransformListLayout.fit(rows: 30, available: -40) == .init(height: 32, scrolls: true))
    }

    @Test func noRowsNeedNoRoom() {
        #expect(TransformListLayout.fit(rows: 0, available: 0) == .init(height: 0, scrolls: false))
    }
}

/// The panel drawn: the list's arithmetic matches its rows and headers, `.chrome` measures everything else with the
/// result at its tallest, and a scrolling list stands exactly as tall as it is told.
@MainActor @Suite struct TransformListDrawingTests {
    let model: PanelViewModel
    let fake = FakeCommands()
    let suite = UserDefaults(suiteName: "yab-xlist-\(UUID().uuidString)")!

    init() throws {
        let store = try ItemStore.temporary()
        // Rich text, so "Paste as plain text" leads, with a result of three full lines: the tallest a result gets.
        let text = String(repeating: "Perşembe toplantısında iade akışının demosu, ödeme ekranı ve bildirim metinleri. ", count: 12)
        let reps = [PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8)),
                    PasteboardRepresentation(type: TypeIdentifiers.rtf, data: Data("{\\rtf1 \(text)}".utf8))]
        let id = try #require(try store.ingest(CapturedClip(items: [reps], source: nil, device: .local, capturedAt: Date()))).item.id!
        fake.transformsByItem[id] = (1...4).map { FakeCommands.command("dev.example.case/upper#\($0)", title: "Büyük harf \($0)", keywords: ["büyük"],
                                                                       extensionName: "Harf") }
            + (1...3).map { FakeCommands.command("dev.example.hash/sha#\($0)", title: "SHA \($0)", keywords: ["sha"], extensionName: "Özet") }
        let language = LanguageStore(defaults: suite)
        language.language = .turkish
        model = PanelViewModel(library: try Library(store: store), language: language, extensions: fake, now: { Date() },
                               shiftDefaults: ShiftReturnDefaults(defaults: suite), shiftHintDelay: .zero)
        model.reset()
        model.select(id, in: .history)
        _ = model.handle(.toggleTransforms)
    }

    func height(_ list: TransformPanelView.ListMode) -> CGFloat {
        NSHostingView(rootView: TransformPanelView(model: model, list: list) { _ in }).fittingSize.height
    }

    @Test func theListIsItsRowsAndHeaders() throws {
        try #require(model.transformRows.count == 8 && model.transformSections.count == 3)
        #expect(model.transformRows.first == .plainText)
        let content = TransformListLayout.contentHeight(rows: model.transformRows.count, sections: model.transformSections.count)
        #expect(height(.full) - height(.chrome) == content)
    }

    @Test func aScrollingListIsAsTallAsItIsTold() {
        #expect(height(.scrolls(height: 100)) == height(.chrome) + 100)
    }

    /// ↑ ↓ and the search bring the highlight into view; pointing at a row highlights it and leaves the list be.
    @Test func theKeyboardRevealsTheHighlightAndThePointerDoesNot() {
        let start = model.transformReveal
        model.highlightMenuRow(5)
        #expect(model.transformReveal == start)
        _ = model.handle(.move(1))
        #expect(model.menuSelection == 6)
        #expect(model.transformReveal == start + 1)
        _ = model.handle(.type("s"))
        #expect(model.menuSelection == 0)
        #expect(model.transformReveal == start + 2)
    }
}
