import AppKit
import Testing
import YabTestSupport
@testable import YabCore
import YabLocalization
import YabPasteboard
@testable import YabUI

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

private func clip(_ s: String, minutesAgo: Double, rtf: Bool = false) -> CapturedClip {
    let plain = PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(s.utf8))
    let reps = rtf ? [plain, PasteboardRepresentation(type: TypeIdentifiers.rtf, data: Data("{\\rtf1 \(s)}".utf8))] : [plain]
    return CapturedClip(items: [reps], source: nil, device: .local, capturedAt: now.addingTimeInterval(-minutesAgo * 60))
}

/// An input method's text in the search: composed (marked) text shows but is not searched; committed text is typed.
@MainActor @Suite struct MarkedTextTests {
    let model: PanelViewModel
    /// Rich text, so the ⇧ panel opens on it ("Paste as plain text") without any extension.
    let richID: Int64

    init() throws {
        let store = try ItemStore(directory: TestScratch.url("items"))
        _ = try store.ingest(clip("你好世界", minutesAgo: 1))
        richID = try #require(try store.ingest(clip("haftalık rapor", minutesAgo: 2, rtf: true))).item.id!
        _ = try store.ingest(clip("eski not", minutesAgo: 3))
        let language = LanguageStore(defaults: TestScratch.defaults("yab-ui"), preferredLanguages: ["en"])
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

    // MARK: Where the composition goes

    /// The search line composes while nothing is open over the list.
    @Test func theSearchComposesWhenNoMenuIsOpen() {
        #expect(model.typingTarget == .search)
        model.setMarkedText("ni")
        #expect(model.markedText(in: .search) == "ni")
        #expect(model.typedText(in: .search) == "")
    }

    @Test func actionsMenuComposesInItsOwnLine() {
        _ = model.handle(.toggleActions)
        #expect(model.typingTarget == .actions)
        model.setMarkedText("fu")
        #expect(model.markedText(in: .actions) == "fu")
        #expect(model.markedText(in: .search) == "")
        #expect(model.actionQuery == "")
        model.commitText("复制")
        #expect(model.actionQuery == "复制")
        #expect(model.typedText(in: .actions) == "复制")
        #expect(model.query == "")
        #expect(model.markedText(in: .actions) == "")
    }

    @Test func pinMenuComposesInItsOwnLine() {
        _ = model.handle(.togglePin)
        #expect(model.layer == .pin)
        #expect(model.typingTarget == .pin)
        model.setMarkedText("ni")
        #expect(model.markedText(in: .pin) == "ni")
        #expect(model.markedText(in: .search) == "")
        model.commitText("你")
        #expect(model.pinQuery == "你")
        #expect(model.typedText(in: .pin) == "你")
        #expect(model.query == "")
    }

    @Test func transformsPanelComposesInItsOwnLine() {
        model.select(richID, in: .history)
        _ = model.handle(.toggleTransforms)
        #expect(model.layer == .transforms)
        #expect(model.typingTarget == .transforms)
        model.setMarkedText("chun")
        #expect(model.markedText(in: .transforms) == "chun")
        #expect(model.markedText(in: .search) == "")
        model.commitText("纯")
        #expect(model.transformQuery == "纯")
        #expect(model.typedText(in: .transforms) == "纯")
        #expect(model.query == "")
    }

    /// Composing is typing for the hover rule too: the ⇧ panel's search line comes with the first composed letter and
    /// moves the rows under a resting pointer; the row that lands there doesn't take the highlight until the pointer moves.
    @Test func composingKeepsTheHighlightUntilThePointerMoves() {
        final class Pointer { var at = CGPoint(x: 300, y: 400) }
        let pointer = Pointer()
        model.pointerLocation = { pointer.at }
        model.select(richID, in: .history)
        _ = model.handle(.toggleTransforms)
        pointer.at.x += 3
        #expect(model.acceptsHover())
        model.setMarkedText("c")
        #expect(!model.acceptsHover())
        pointer.at.y -= 2
        #expect(model.acceptsHover())
        model.setMarkedText("")
        #expect(!model.acceptsHover())
    }

    @Test func transformsMenuComposesInItsOwnLine() {
        model.select(richID, in: .history)
        _ = model.handle(.toggleTransforms)
        _ = model.handle(.toggleActions)
        #expect(model.transformMenuOpen)
        #expect(model.typingTarget == .transformMenu)
        model.setMarkedText("mo")
        #expect(model.markedText(in: .transformMenu) == "mo")
        #expect(model.markedText(in: .transforms) == "")
        model.commitText("默认")
        #expect(model.transformMenuQuery == "默认")
        #expect(model.typedText(in: .transformMenu) == "默认")
        #expect(model.transformQuery == "")
    }

    /// The Kategoriler menu takes no typing: nothing composes in any line.
    @Test func categoryMenuComposesNowhere() {
        _ = model.handle(.toggleCategoryMenu)
        #expect(model.typingTarget == nil)
        model.setMarkedText("ni")
        #expect(model.markedText(in: .search) == "")
    }

    /// A ⌘A selection is the search's: composing in an open menu leaves it.
    @Test func composingInAMenuKeepsTheSearchSelection() {
        _ = model.handle(.type("rapor"))
        _ = model.handle(.selectAll)
        _ = model.handle(.toggleActions)
        model.setMarkedText("ni")
        #expect(model.query == "rapor")
        #expect(model.isQuerySelected)
    }

    @Test func aFreshPanelComposesNothing() {
        model.setMarkedText("ni")
        model.reset()
        #expect(model.markedText == "")
    }

    // MARK: A composition the panel ends

    /// Counts the times the model tells the input method to let go of its composition (`discardMarkedText`).
    final class Discards {
        var count = 0
    }

    func countDiscards() -> Discards {
        let discards = Discards()
        model.discardInputMethodComposition = { discards.count += 1 }
        return discards
    }

    /// ⌘K or ⌘P while composing commits the text in the line it was composed in, as a text field does when focus
    /// leaves it; the menu opens with an empty line, and the input method lets go of its composition.
    @Test(arguments: [PanelCommand.toggleActions, .togglePin])
    func aMenuShortcutCommitsTheComposition(_ shortcut: PanelCommand) {
        let discards = countDiscards()
        model.setMarkedText("rap")
        _ = model.handle(shortcut)
        #expect(model.layer == (shortcut == .toggleActions ? .actions : .pin))
        #expect(model.query == "rap")
        #expect(model.markedText == "")
        #expect(model.actionQuery == "")
        #expect(model.pinQuery == "")
        #expect(discards.count == 1)
    }

    /// ⌘T closing the ⇧ panel mid-composition leaves nothing composing in the search under it.
    @Test func commandTCommitsTheComposition() {
        let discards = countDiscards()
        model.select(richID, in: .history)
        _ = model.handle(.toggleTransforms)
        model.setMarkedText("chun")
        _ = model.handle(.toggleTransforms)
        #expect(model.layer == .none)
        #expect(model.markedText == "")
        #expect(model.markedText(in: .search) == "")
        #expect(model.query == "")
        #expect(discards.count == 1)
    }

    /// ⌘K inside ⌘K's own composition: the text stays in ⌘K's line as the menu closes; the search never gets it.
    @Test func closingAMenuCommitsInItsLine() {
        _ = model.handle(.toggleActions)
        model.setMarkedText("fu")
        _ = model.handle(.toggleActions)
        #expect(model.layer == .none)
        #expect(model.markedText(in: .search) == "")
        #expect(model.query == "")
    }

    /// Shortcuts that open no line leave the composition where it is.
    @Test func otherShortcutsLeaveTheComposition() {
        let discards = countDiscards()
        model.setMarkedText("ni")
        _ = model.handle(.selectAll)
        _ = model.handle(.commandHeld(true))
        #expect(model.markedText == "ni")
        #expect(discards.count == 0)
    }

    /// An Esc the input method passes on drops the composition here and in the input method, which would otherwise
    /// bring the text back with its next key.
    @Test func aPassedOnEscapeTellsTheInputMethod() {
        let discards = countDiscards()
        model.setMarkedText("ni")
        #expect(model.handle(.escape) == nil)
        #expect(model.markedText == "")
        #expect(model.query == "")
        #expect(discards.count == 1)
    }

    /// An input method may hand its composition back as it lets go (`insertText` after `discardMarkedText`, at once or
    /// a moment later): it is not typed again, whether Esc dropped it or a shortcut already committed it.
    @Test func theTextHandedBackIsNotTypedTwice() {
        // At once, from inside the discard.
        final class Echo { var text = "" }
        let echo = Echo()
        model.discardInputMethodComposition = { [model] in model.commitText(echo.text) }
        echo.text = "ni"
        model.setMarkedText("ni")
        _ = model.handle(.escape)
        #expect(model.query == "")

        echo.text = "rap"
        model.setMarkedText("rap")
        _ = model.handle(.toggleActions)
        #expect(model.query == "rap")
        #expect(model.actionQuery == "")
        _ = model.handle(.escape)

        // A moment later.
        model.discardInputMethodComposition = {}
        model.setMarkedText("or")
        _ = model.handle(.toggleActions)
        model.commitText("or")
        #expect(model.query == "rapor")
        #expect(model.actionQuery == "")
        // What comes after is typed as usual.
        model.commitText("复制")
        #expect(model.actionQuery == "复制")
    }

    /// A new composition means the input method answered: the same text committed then is typed.
    @Test func aNewCompositionIsTypedEvenIfItMatches() {
        model.discardInputMethodComposition = {}
        model.setMarkedText("ni")
        _ = model.handle(.escape)
        model.setMarkedText("ni")
        model.commitText("ni")
        #expect(model.query == "ni")
    }

    /// The panel closing ends a composition without a result, in the model and in the input method.
    @Test func closingThePanelDropsTheComposition() {
        let input = PanelTextInputView(model: model)
        let discards = countDiscards()
        model.setMarkedText("ni")
        input.discardComposition()
        #expect(model.markedText == "")
        #expect(model.query == "")
        #expect(discards.count == 1)
        input.discardComposition()
        #expect(discards.count == 1)
    }
}

/// Where an input method's candidate window goes: measured from the line's leading edge, so it never depends on the line
/// having been laid out for the newest text, and kept inside the line.
@MainActor @Suite struct CompositionRectTests {
    let line = NSRect(x: 20, y: 5, width: 200, height: 21)
    let font = LineFont.search

    func rect(_ range: NSRange, in text: String) -> (rect: NSRect, found: NSRange) {
        LineFont.compositionRect(of: range, in: text as NSString, line: line, font: font)
    }

    @Test func theStartIsTheLineStart() {
        let (rect, found) = rect(NSRange(location: 0, length: 2), in: "ni")
        #expect(rect.minX == line.minX)
        #expect(rect.width == font.width(of: "ni"))
        #expect(rect.minY == line.minY)
        #expect(rect.height == line.height)
        #expect(found == NSRange(location: 0, length: 2))
    }

    /// Marked text after a typed query starts where the query ends.
    @Test func markedTextStartsAfterTheQuery() {
        let (rect, _) = rect(NSRange(location: 2, length: 2), in: "你好ni")
        #expect(rect.minX == line.minX + font.width(of: "你好"))
        #expect(rect.width == font.width(of: "ni"))
    }

    @Test func noLocationMeansTheEnd() {
        let (rect, found) = rect(NSRange(location: NSNotFound, length: 0), in: "nihao")
        #expect(rect.minX == line.minX + font.width(of: "nihao"))
        #expect(found == NSRange(location: 5, length: 0))
    }

    @Test func aRangePastTheTextIsClamped() {
        let (_, found) = rect(NSRange(location: 3, length: 10), in: "nihao")
        #expect(found == NSRange(location: 3, length: 2))
    }

    /// A query longer than the line is cut at its end; the candidate window stays under the line.
    @Test func aLongQueryStaysInsideTheLine() {
        let long = String(repeating: "长", count: 40)
        let (rect, _) = rect(NSRange(location: 38, length: 2), in: long)
        #expect(rect.minX == line.maxX)
        #expect(rect.width == 0)
    }
}
