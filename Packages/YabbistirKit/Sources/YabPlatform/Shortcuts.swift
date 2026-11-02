import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Opens or closes the history panel. Default ⇧⌘V, same as Paste.
    public static let togglePanel = Self("togglePanel", default: .init(.v, modifiers: [.command, .shift]))
    /// Copies the selection into the Sıra, opening it when closed. Default ⇧⌘C, same as Paste.
    public static let stackCopy = Self("stackCopy", default: .init(.c, modifiers: [.command, .shift]))
    /// While the new-copy rail shows: move that copy to the top, or to second place.
    public static let stackToFirst = Self("stackToFirst", default: .init(.one, modifiers: [.option]))
    public static let stackToSecond = Self("stackToSecond", default: .init(.two, modifiers: [.option]))
    /// While the Sıra is open and secure input hides keystrokes from its tap: ⌘V, so the Sıra still hears it.
    public static let stackPaste = Self("stackPaste", default: .init(.v, modifiers: [.command]))
}

/// Registers global shortcut handlers so the app target need not import KeyboardShortcuts.
@MainActor
public enum GlobalShortcuts {
    public static func onTogglePanel(_ action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .togglePanel, action: action)
    }

    /// Puts the two user-facing shortcuts back to their defaults.
    public static func resetToDefaults() {
        for shortcut in GlobalShortcut.allCases { KeyboardShortcuts.reset(shortcut.name) }
    }

    public static func onStackCopy(_ action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .stackCopy, action: action)
    }

    /// ⌥1 / ⌥2 type characters everywhere else, so they start off and are claimed only while
    /// the rail offers them (`setRailShortcuts`).
    public static func onRail(first: @escaping () -> Void, second: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .stackToFirst, action: first)
        KeyboardShortcuts.onKeyUp(for: .stackToSecond, action: second)
        setRailShortcuts(first: false, second: false)
    }

    /// ⌘V is every app's paste, so it starts off and is claimed only while secure input hides it from the Sıra's
    /// tap (`setStackPaste`).
    public static func onStackPaste(_ action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .stackPaste, action: action)
        setStackPaste(claimed: false)
    }

    public static func setStackPaste(claimed: Bool) {
        if claimed { KeyboardShortcuts.enable(.stackPaste) } else { KeyboardShortcuts.disable(.stackPaste) }
    }

    public static func setRailShortcuts(first: Bool, second: Bool) {
        for (name, claimed) in [(KeyboardShortcuts.Name.stackToFirst, first), (.stackToSecond, second)] {
            if claimed { KeyboardShortcuts.enable(name) } else { KeyboardShortcuts.disable(name) }
        }
    }
}
