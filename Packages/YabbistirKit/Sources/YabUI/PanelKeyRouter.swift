import AppKit

public enum PanelCommand: Equatable, Sendable {
    case type(String), deleteBackward, move(Int), confirm(plain: Bool), escape, selectAll
    case moveColumn(Int), pasteIndex(Int), copy, delete
    /// ⌥↑ / ⌥↓: move the selected Sıra row up or down the stack.
    case moveItem(Int)
    case toggleActions, togglePin, toggleCategoryMenu, openEditor, togglePreview
    /// ⌘ pressed or released on its own (flagsChanged).
    case commandHeld(Bool)
    /// A bare ⇧ tap (`ShiftTapDetector`) or the footer's Transform: the ⇧ panel.
    case toggleTransforms
    /// A ⌘ shortcut the panel does not use; consumed so it never reaches the main menu.
    case swallow
}

/// Maps raw key events in the panel to commands. Typing goes straight to search; ⌘ shortcuts
/// match by character, so they follow the keyboard layout. Every ⌘ combination is consumed:
/// the panel has no menu, and ⌘Q or ⌘, must not reach the app's main menu.
public enum PanelKeyRouter {
    public static func command(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> PanelCommand? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        switch keyCode {
        case 36, 76: return .confirm(plain: modifiers.contains(.shift))
        case 125 where modifiers.contains(.option): return .moveItem(1)
        case 126 where modifiers.contains(.option): return .moveItem(-1)
        case 125: return .move(1)
        case 126: return .move(-1)
        case 123: return .moveColumn(-1)
        case 124: return .moveColumn(1)
        case 121: return .move(6)
        case 116: return .move(-6)
        case 48: return .toggleCategoryMenu
        case 53: return .escape
        case 51: return modifiers.contains(.command) ? .delete : .deleteBackward
        default: break
        }
        if modifiers.contains(.command) {
            guard modifiers.isDisjoint(with: [.control, .option, .shift]), let key = characters?.lowercased() else { return .swallow }
            if let digit = Int(key), (1...9).contains(digit) { return .pasteIndex(digit) }
            switch key {
            case "a": return .selectAll
            case "c": return .copy
            case "k": return .toggleActions
            case "p": return .togglePin
            case "e": return .openEditor
            default: return .swallow
            }
        }
        if modifiers.contains(.control) { return nil }
        if keyCode == 49 { return .togglePreview }
        guard let characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) && $0.value != 0x7F })
        else { return nil }
        return .type(characters)
    }

    /// True while ⌘ is down on its own (no ⇧, ⌥ or ⌃), from a flagsChanged event.
    public static func commandHeld(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .control, .option, .shift]) == .command
    }
}
