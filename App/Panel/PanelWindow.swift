import AppKit
import YabUI

/// Borderless, non-activating panel: it takes keyboard focus for search while the
/// app the user is typing in stays active, so the paste lands back there.
final class PanelWindow: NSPanel {
    var onCommand: ((PanelCommand) -> Void)?
    /// Whether the bar shows the ⇧↵ hint: a ⇧ let go while it shows was held, not tapped.
    var showsShiftHint: () -> Bool = { false }
    private var shiftTap = ShiftTapDetector()

    init() {
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
        sharingType = .none // hidden during screen sharing (spec default)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘ shortcuts arrive here before the main menu sees them; the router consumes all of them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command),
              let command = PanelKeyRouter.command(keyCode: event.keyCode, characters: event.characters, modifiers: event.modifierFlags)
        else { return super.performKeyEquivalent(with: event) }
        onCommand?(command)
        return true
    }

    /// Routes keys before SwiftUI sees them, so typing always goes to search.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            // A bare ⇧ tap opens (or closes) the transforms of the selected item; a hold long enough
            // to show the ⇧↵ hint is no tap. Both are read before the hint goes.
            let tapped = shiftTap.flagsChanged(event.modifierFlags, at: event.timestamp) && !showsShiftHint()
            onCommand?(.commandHeld(PanelKeyRouter.commandHeld(event.modifierFlags)))
            if tapped { onCommand?(.toggleTransforms) }
            // ⇧ alone starts the hint's delay; let go, or joined by another modifier, it ends the hint.
            onCommand?(.shiftHeld(PanelKeyRouter.shiftHeld(event.modifierFlags)))
        }
        if event.type == .keyDown { shiftTap.keyDown() }
        if event.type == .keyDown,
           let command = PanelKeyRouter.command(keyCode: event.keyCode, characters: event.characters, modifiers: event.modifierFlags) {
            onCommand?(command)
            return
        }
        super.sendEvent(event)
    }
}
