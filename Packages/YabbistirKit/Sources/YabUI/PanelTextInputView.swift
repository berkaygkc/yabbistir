import AppKit
import SwiftUI

/// The panel's window: it keeps the search's text input view, to hand it the keys an input method takes.
@MainActor public protocol PanelTextInputHost: AnyObject {
    var textInput: PanelTextInputView? { get set }
}

/// The search line's text input client, so macOS input methods (Pinyin, Kana, Hangul…) compose into the search. It is
/// the panel window's first responder and draws nothing: it sits behind the search text, its bounds the text's, so the
/// candidate window opens just under what is being written. The window decides which keys reach it
/// (`PanelKeyRouter.route`).
public final class PanelTextInputView: NSView, @preconcurrency NSTextInputClient {
    var model: PanelViewModel

    init(model: PanelViewModel) {
        self.model = model
        super.init(frame: .zero)
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
        window.makeFirstResponder(self)
    }

    /// A key the panel has no use for (the window passed it on): under an input method it is the method's (かな, 英数);
    /// on a plain layout it goes up the responder chain, as before.
    override public func keyDown(with event: NSEvent) {
        if model.inputMethodActive, inputContext?.handleEvent(event) == true { return }
        super.keyDown(with: event)
    }

    /// The panel is closing: a composition left open ends with it, without a result.
    public func discardComposition() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        model.setMarkedText("")
    }

    /// The search as the input method sees it: the query, then the text being composed.
    private var text: NSString { (model.query + model.markedText) as NSString }

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
        return NSRange(location: (model.query as NSString).length, length: (model.markedText as NSString).length)
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

    /// The marked text keeps the search's own look, underlined by the search line.
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where `range` is drawn, in screen coordinates. The view spans the drawn text, so its trailing edge is exact; the
    /// start of `range` is measured back from it in the search's font.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let text = text
        let start = range.location == NSNotFound ? text.length : min(range.location, text.length)
        let found = NSRange(location: start, length: min(range.length, text.length - start))
        actualRange?.pointee = found
        guard let window else { return .zero }
        let rect = NSRect(x: bounds.maxX - Self.width(text.substring(from: start)), y: bounds.minY,
                          width: Self.width(text.substring(with: found)), height: bounds.height)
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// The panel floats; the candidate window opens above it.
    public func windowLevel() -> Int { (window?.level ?? .floating).rawValue }

    private static func width(_ string: String) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Tokens.Fonts.searchSize), .tracking: Tokens.Fonts.searchTracking,
        ]
        return NSAttributedString(string: string, attributes: attributes).size().width
    }
}

/// Puts the search's text input view behind the search text.
struct PanelTextInput: NSViewRepresentable {
    let model: PanelViewModel

    func makeNSView(context: Context) -> PanelTextInputView { PanelTextInputView(model: model) }

    func updateNSView(_ view: PanelTextInputView, context: Context) {
        view.model = model
    }
}
