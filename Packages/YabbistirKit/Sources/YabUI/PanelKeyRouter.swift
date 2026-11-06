import AppKit

public enum PanelCommand: Equatable, Sendable {
    case type(String), deleteBackward, move(Int), confirm(plain: Bool), escape, selectAll
    case moveColumn(Int), pasteIndex(Int), copy, delete
    /// ⌥↑ / ⌥↓: move the selected Sıra row up or down the stack.
    case moveItem(Int)
    case toggleActions, togglePin, toggleCategoryMenu, openEditor, togglePreview
    /// ⌘ pressed or released on its own (flagsChanged).
    case commandHeld(Bool)
    /// ⇧ pressed or released on its own (flagsChanged): held, the bar says what ⇧↵ does.
    case shiftHeld(Bool)
    /// A bare ⇧ tap (`ShiftTapDetector`), ⌘T or the footer's Transform: the ⇧ panel.
    case toggleTransforms
    /// A ⌘ shortcut the panel does not use; consumed so it never reaches the main menu.
    case swallow
}

/// Where a key in the panel goes: to the input method (Pinyin, Kana, Hangul…) composing in the search, to the panel as a
/// command, or on to the system (`super.sendEvent`).
public enum PanelKeyRoute: Equatable, Sendable {
    case inputMethod, command(PanelCommand), system
}

/// Maps raw key events in the panel to commands. Typing goes straight to search; ⌘ shortcuts
/// match by character, so they follow the keyboard layout. Every ⌘ combination is consumed:
/// the panel has no menu, and ⌘Q or ⌘, must not reach the app's main menu.
public enum PanelKeyRouter {
    /// While text is being composed (`composing`), every key without ⌘ belongs to the input method: ↵, Esc, the arrows,
    /// Space and ⌫ never paste, close or move. With an input method active (`inputMethod`), typing starts with it too,
    /// where a line takes text (`acceptsText`; not the Kategoriler menu or a source's list, where nothing would show the
    /// composition). The panel's own keys (Space, ↵, Esc, arrows, ⇥, ⌫) work as on any layout while nothing is composed.
    public static func route(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                             composing: Bool, inputMethod: Bool, acceptsText: Bool = true) -> PanelKeyRoute {
        if composing, !modifiers.contains(.command) { return .inputMethod }
        guard let command = command(keyCode: keyCode, characters: characters, modifiers: modifiers) else { return .system }
        if case .type = command, inputMethod, acceptsText { return .inputMethod }
        return .command(command)
    }

    /// A bare ⇧ tap opens the ⇧ panel on a plain layout; under an input method ⇧ is its own (Pinyin switches to Latin
    /// letters with it), and ⌘T opens the panel instead.
    public static func shiftTapCommand(inputMethod: Bool) -> PanelCommand? {
        inputMethod ? nil : .toggleTransforms
    }

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
            guard modifiers.isDisjoint(with: [.control, .option, .shift]), var key = characters?.lowercased() else { return .swallow }
            // Hangul or Kana under ⌘ ("ㅏ" for K): the key's place on an ANSI keyboard names the shortcut. A Latin
            // layout's own keys (ğ on Turkish F, é and § on AZERTY, š on Czech) stay what they are.
            if !isLatin(key), let ansi = ansiKeys[keyCode] { key = ansi }
            if let digit = Int(key), (1...9).contains(digit) { return .pasteIndex(digit) }
            switch key {
            case "a": return .selectAll
            case "c": return .copy
            case "k": return .toggleActions
            case "p": return .togglePin
            case "e": return .openEditor
            case "t": return .toggleTransforms
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

    /// Latin script with its symbols: ASCII, Latin-1, Latin Extended-A and -B, and Latin Extended Additional (Vietnamese).
    private static func isLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x250 || (0x1E00...0x1EFF).contains($0.value) }
    }

    /// The ⌘ shortcuts' keys by ANSI key code, for a layout that types no Latin letter under ⌘.
    private static let ansiKeys: [UInt16: String] = [
        0: "a", 8: "c", 40: "k", 35: "p", 14: "e", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]

    /// True while ⌘ is down on its own (no ⇧, ⌥ or ⌃), from a flagsChanged event.
    public static func commandHeld(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .control, .option, .shift]) == .command
    }

    /// True while ⇧ is down on its own (no ⌘, ⌥ or ⌃), from a flagsChanged event.
    public static func shiftHeld(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .control, .option, .shift]) == .shift
    }
}
