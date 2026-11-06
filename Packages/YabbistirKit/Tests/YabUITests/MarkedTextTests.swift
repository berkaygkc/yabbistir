import Foundation
import Testing
@testable import YabCore
import YabLocalization
import YabPasteboard
@testable import YabUI

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

private func clip(_ s: String, minutesAgo: Double) -> CapturedClip {
    CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(s.utf8))]],
                 source: nil, device: .local, capturedAt: now.addingTimeInterval(-minutesAgo * 60))
}

/// An input method's text in the search: composed (marked) text shows but is not searched; committed text is typed.
@MainActor @Suite struct MarkedTextTests {
    let model: PanelViewModel

    init() throws {
        let store = try ItemStore.temporary()
        for (text, minutes) in [("你好世界", 1.0), ("haftalık rapor", 2), ("eski not", 3)] {
            _ = try store.ingest(clip(text, minutesAgo: minutes))
        }
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-ui-\(UUID().uuidString)")!)
        model = PanelViewModel(library: try Library(store: store), language: language, now: { now })
        model.reset()
    }

    var titles: [String] { model.columns.first { $0.id == .history }?.rows.map(\.title) ?? [] }

    @Test func markedTextIsNotSearched() {
        let before = titles
        let selected = model.selectedID
        model.setMarkedText("ni")
        #expect(model.markedText == "ni")
        #expect(model.query == "")
        #expect(titles == before)
        #expect(model.selectedID == selected)
    }

    @Test func committedTextIsTyped() {
        model.setMarkedText("ni")
        model.commitText("你")
        #expect(model.query == "你")
        #expect(model.markedText == "")
    }

    @Test func committedTextSearches() {
        model.commitText("rapor")
        #expect(titles == ["haftalık rapor"])
    }

    @Test func escapeWithoutMarkedTextBehavesAsToday() {
        _ = model.handle(.type("rapor"))
        #expect(model.handle(.escape) == nil)
        #expect(model.query == "")
        #expect(model.handle(.escape) == .close)
    }

    /// The window hands these keys to the input method while it composes; one that still reaches the model never
    /// pastes, moves or closes the panel, and Esc drops the composition.
    @Test func keysTheInputMethodOwnsNeverActWhileComposing() {
        model.setMarkedText("ni")
        let selected = model.selectedID
        #expect(model.handle(.confirm(plain: false)) == nil)
        #expect(model.handle(.move(1)) == nil)
        #expect(model.selectedID == selected)
        #expect(model.handle(.togglePreview) == nil)
        #expect(!model.isPreviewVisible)
        #expect(model.handle(.escape) == nil)
        #expect(model.markedText == "")
        #expect(model.handle(.escape) == .close)
    }

    /// As in a text field, composing over a ⌘A-selected search replaces it.
    @Test func composingOverASelectedSearchReplacesIt() {
        _ = model.handle(.type("rapor"))
        _ = model.handle(.selectAll)
        model.setMarkedText("ni")
        #expect(model.query == "")
        #expect(!model.isQuerySelected)
        #expect(model.markedText == "ni")
    }

    /// `unmarkText` with nothing composed commits nothing: the search and its selection stay.
    @Test func emptyCommitLeavesTheSearch() {
        _ = model.handle(.type("o"))
        _ = model.handle(.move(1))
        let selected = model.selectedID
        model.commitText("")
        #expect(model.query == "o")
        #expect(model.selectedID == selected)
    }

    @Test func aFreshPanelComposesNothing() {
        model.setMarkedText("ni")
        model.reset()
        #expect(model.markedText == "")
    }
}
