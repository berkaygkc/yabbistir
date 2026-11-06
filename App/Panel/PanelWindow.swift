import AppKit
import YabUI

/// Borderless, non-activating panel: it takes keyboard focus for search while the
/// app the user is typing in stays active, so the paste lands back there.
final class PanelWindow: NSPanel, PanelTextInputHost {
    var onCommand: ((PanelCommand) -> Void)?
    /// Whether the bar shows the ⇧↵ hint: a ⇧ let go while it shows was held, not tapped.
    var showsShiftHint: () -> Bool = { false }
    /// The keyboard's input source became an input method (Pinyin, Kana, Hangul…), or stopped being one.
    var onInputMethodChange: ((Bool) -> Void)?
    /// The search's text input view, which registers itself: the keys an input method takes go to its input context.
    weak var textInput: PanelTextInputView?
    private(set) var inputMethodActive = false
    private var shiftTap = ShiftTapDetector()

    init(sharingType: NSWindow.SharingType) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.sharingType = sharingType
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardSelectionChanged),
                                               name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Reads the input source again: when the panel shows, when the keyboard selection changes, and on every key, so a
    /// switch the notification missed never sends letters past the input method.
    @discardableResult func refreshInputSource() -> Bool {
        let active = InputSource.isInputMethod()
        if active != inputMethodActive {
            inputMethodActive = active
            onInputMethodChange?(active)
        }
        return active
    }

    @objc private func keyboardSelectionChanged(_ notification: Notification) {
        refreshInputSource()
    }

    /// A composition left open ends with the panel; the next one starts clean.
    override func orderOut(_ sender: Any?) {
        textInput?.discardComposition()
        super.orderOut(sender)
    }

    /// ⌘ shortcuts arrive here before the main menu sees them; the router consumes all of them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command),
              let command = PanelKeyRouter.command(keyCode: event.keyCode, characters: event.characters, modifiers: event.modifierFlags)
        else { return super.performKeyEquivalent(with: event) }
        onCommand?(command)
        return true
    }

    /// Routes keys before SwiftUI sees them: typing goes to search, through the input method when one is active
    /// (`PanelKeyRouter.route`).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            // A bare ⇧ tap opens (or closes) the transforms of the selected item, on a plain layout; a hold long
            // enough to show the ⇧↵ hint is no tap. Both are read before the hint goes. Under an input method the tap
            // is the method's (Pinyin switches to Latin letters with it): AppKit has already handed it the change,
            // through the text input view's input context.
            let tapped = shiftTap.flagsChanged(event.modifierFlags, at: event.timestamp) && !showsShiftHint()
            onCommand?(.commandHeld(PanelKeyRouter.commandHeld(event.modifierFlags)))
            if tapped, let command = PanelKeyRouter.shiftTapCommand(inputMethod: refreshInputSource()) { onCommand?(command) }
            // ⇧ alone starts the hint's delay; let go, or joined by another modifier, it ends the hint.
            onCommand?(.shiftHeld(PanelKeyRouter.shiftHeld(event.modifierFlags)))
        }
        if event.type == .keyDown {
            shiftTap.keyDown()
            let route = PanelKeyRouter.route(keyCode: event.keyCode, characters: event.characters, modifiers: event.modifierFlags,
                                             composing: textInput?.hasMarkedText() ?? false, inputMethod: refreshInputSource())
            switch route {
            case .inputMethod:
                if inputMethodTakes(event) { return }
                // The input method left it (or there is no input context): it works as on a plain layout.
                if let command = PanelKeyRouter.command(keyCode: event.keyCode, characters: event.characters,
                                                        modifiers: event.modifierFlags) {
                    onCommand?(command)
                    return
                }
            case .command(let command):
                onCommand?(command)
                return
            case .system:
                break
            }
        }
        super.sendEvent(event)
    }

    /// Hands a key to the search's input context; the text input view becomes first responder again if a click took it.
    private func inputMethodTakes(_ event: NSEvent) -> Bool {
        guard let textInput else { return false }
        if firstResponder !== textInput { makeFirstResponder(textInput) }
        return textInput.inputContext?.handleEvent(event) ?? false
    }
}
