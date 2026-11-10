import AppKit
import SwiftUI

/// The panel's window: it keeps the search's text input view, to hand it the keys an input method takes.
@MainActor public protocol PanelTextInputHost: AnyObject {
    var textInput: PanelTextInputView? { get set }
}

/// The panel's text input client, so macOS input methods (Pinyin, Kana, Hangul…) compose where typing goes: the search,
/// or the open menu's own search line (`PanelViewModel.typingTarget`). It is the panel window's first responder and
/// draws nothing; it sits behind the search line. The window decides which keys reach it (`PanelKeyRouter.route`).
public final class PanelTextInputView: NSView, @preconcurrency NSTextInputClient {
    var model: PanelViewModel {
        didSet { if model !== oldValue { listen() } }
    }

    init(model: PanelViewModel) {
        self.model = model
        super.init(frame: .zero)
        listen()
    }

    /// A composition the model ends itself (Esc the input method passed on, ⌘K, ⌘P, ⌘T, the panel closing) ends in the
    /// input method too.
    private func listen() {
        model.discardInputMethodComposition = { [weak self] in self?.inputContext?.discardMarkedText() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override public var acceptsFirstResponder: Bool { true }

    /// Clicks belong to the SwiftUI views around it.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        (window as? PanelTextInputHost)?.textInput = self
        model.textInputAnchors.register(self, for: .search, font: .search)
        window.makeFirstResponder(self)
    }

    /// A key the panel has no use for (the window passed it on): under an input method it is the method's (かな, 英数);
    /// on a plain layout it goes up the responder chain, as before.
    override public func keyDown(with event: NSEvent) {
        if model.inputMethodActive, inputContext?.handleEvent(event) == true { return }
        super.keyDown(with: event)
    }

    /// Some line takes typing now; the Kategoriler menu and a source's list take none.
    public var acceptsText: Bool { model.typingTarget != nil }

    /// The panel is closing: a composition left open ends with it, without a result.
    public func discardComposition() {
        model.endComposition(committing: false)
    }

    /// The line typing goes to; the search's while typing goes nowhere (the Kategoriler menu).
    private var target: TypingTarget { model.typingTarget ?? .search }

    /// That line as the input method sees it: its query, then the text being composed.
    private var text: NSString { (model.typedText(in: target) + model.markedText) as NSString }

    private static func plain(_ string: Any) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        model.commitText(Self.plain(string))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        model.setMarkedText(Self.plain(string))
    }

    /// Accepts the text being composed as typed.
    public func unmarkText() {
        model.commitText(model.markedText)
    }

    /// A key the input method passes on (↵ or an arrow that ended a Hangul syllable) was typed while composing: it never
    /// pastes, moves or closes. The panel's own keys reach the panel through the window, not through here.
    override public func doCommand(by selector: Selector) {}

    public func selectedRange() -> NSRange {
        NSRange(location: text.length, length: 0)
    }

    public func markedRange() -> NSRange {
        guard hasMarkedText() else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: (model.typedText(in: target) as NSString).length, length: (model.markedText as NSString).length)
    }

    public func hasMarkedText() -> Bool {
        !model.markedText.isEmpty
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let text = text
        guard range.location != NSNotFound, range.location <= text.length else { return nil }
        let clamped = NSRange(location: range.location, length: min(range.length, text.length - range.location))
        actualRange?.pointee = clamped
        return NSAttributedString(string: text.substring(with: clamped))
    }

    /// The marked text keeps its line's own look, underlined by the line.
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where `range` is drawn in the target's line, in screen coordinates; that line may be in another window (the ⇧
    /// panel, ⌘P).
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // The input method asks while the key is still being handled: a line that has just appeared (the ⇧ panel's
        // search, on the first letter) is laid out first.
        for window in [window].compactMap({ $0 }) + (window?.childWindows ?? []) { window.contentView?.layoutSubtreeIfNeeded() }
        let anchors = model.textInputAnchors
        guard let anchor = anchors.anchor(for: target) ?? anchors.anchor(for: .search), let window = anchor.view.window else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return .zero
        }
        let (rect, found) = LineFont.compositionRect(of: range, in: text, line: anchor.view.bounds, font: anchor.font)
        actualRange?.pointee = found
        return window.convertToScreen(anchor.view.convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// The panel floats; the candidate window opens above it.
    public func windowLevel() -> Int { (window?.level ?? .floating).rawValue }
}

/// Puts the panel's text input view behind the search line.
struct PanelTextInput: NSViewRepresentable {
    let model: PanelViewModel

    func makeNSView(context: Context) -> PanelTextInputView { PanelTextInputView(model: model) }

    func updateNSView(_ view: PanelTextInputView, context: Context) {
        view.model = model
    }
}

// MARK: Search lines

/// A search line's font, to find where a position in its text is drawn.
struct LineFont {
    let size: CGFloat
    var tracking: CGFloat = 0

    static let search = LineFont(size: Tokens.Fonts.searchSize, tracking: Tokens.Fonts.searchTracking)
    /// ⌘K's and ⌘P's search lines.
    static let body = LineFont(size: Tokens.Fonts.bodySize)

    func width(of string: String) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .tracking: tracking]
        return NSAttributedString(string: string, attributes: attributes).size().width
    }

    /// Where `range` of a line's `text` is drawn, in the coordinates of `line`, the view behind the line, whose leading
    /// edge is where the text starts. Measured from that edge, so it holds however late the line is laid out for the
    /// newest text; kept inside the line, where a long query is cut. `found` is the range the rect covers.
    static func compositionRect(of range: NSRange, in text: NSString, line: NSRect,
                                font: LineFont) -> (rect: NSRect, found: NSRange) {
        let start = range.location == NSNotFound ? text.length : min(range.location, text.length)
        let found = NSRange(location: start, length: min(range.length, text.length - start))
        let x = min(line.minX + font.width(of: text.substring(to: start)), line.maxX)
        let width = min(font.width(of: text.substring(with: found)), line.maxX - x)
        return (NSRect(x: x, y: line.minY, width: width, height: line.height), found)
    }
}

extension AttributedString {
    /// A search line's text: what has been typed, then what an input method is composing, underlined as macOS marks it.
    static func typed(_ typed: String, marked: String) -> AttributedString {
        var text = AttributedString(typed)
        guard !marked.isEmpty else { return text }
        var composing = AttributedString(marked)
        composing.underlineStyle = .single
        text.append(composing)
        return text
    }
}

/// Where each search line is: an empty AppKit view behind every line registers here (`TextInputAnchor`), and the text
/// input view asks it where an input method's candidate window goes.
@MainActor final class TextInputAnchors {
    private struct Entry {
        weak var view: NSView?
        let font: LineFont
    }

    private var entries: [TypingTarget: Entry] = [:]

    func register(_ view: NSView, for target: TypingTarget, font: LineFont) {
        entries[target] = Entry(view: view, font: font)
    }

    /// `target`'s line while it is on screen.
    func anchor(for target: TypingTarget) -> (view: NSView, font: LineFont)? {
        guard let entry = entries[target], let view = entry.view, view.window?.isVisible == true else { return nil }
        return (view, entry.font)
    }
}

extension EnvironmentValues {
    /// Set by the live panel and its surfaces only: ImageRenderer draws the AppKit views behind the lines as placeholders.
    @Entry var textInputAnchors: TextInputAnchors? = nil
}

public extension View {
    /// Lets the search lines in a surface of the live panel (the ⇧ panel, ⌘P) tell an input method where they are.
    func textInputAnchors(of model: PanelViewModel) -> some View {
        environment(\.textInputAnchors, model.textInputAnchors)
    }
}

/// Behind a search line's text area, its leading edge where the text starts: an input method's candidate window opens
/// under the text being composed there.
struct TextInputAnchor: View {
    let target: TypingTarget
    let font: LineFont
    @Environment(\.textInputAnchors) private var anchors

    var body: some View {
        if let anchors { Marker(target: target, font: font, anchors: anchors) }
    }

    private struct Marker: NSViewRepresentable {
        let target: TypingTarget
        let font: LineFont
        let anchors: TextInputAnchors

        func makeNSView(context: Context) -> MarkerView {
            let view = MarkerView()
            anchors.register(view, for: target, font: font)
            return view
        }

        func updateNSView(_ view: MarkerView, context: Context) {
            anchors.register(view, for: target, font: font)
        }
    }

    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
