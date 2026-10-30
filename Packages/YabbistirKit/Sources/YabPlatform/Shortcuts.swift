import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Opens or closes the history panel. Default ⇧⌘V, same as Paste.
    public static let togglePanel = Self("togglePanel", default: .init(.v, modifiers: [.command, .shift]))
    /// Copies the selection into the Sıra, opening it when closed. Default ⇧⌘C, same as Paste.
    public static let stackCopy = Self("stackCopy", default: .init(.c, modifiers: [.command, .shift]))
    /// While the new-copy rail shows: move that copy to the top, or to second place.
    public static let stackToFirst = Self("stackToFirst", default: .init(.one, modifiers: [.option]))
    public static let stackToSecond = Self("stackToSecond", default: .init(.two, modifiers: [.option]))
}

/// Registers global shortcut handlers so the app target need not import KeyboardShortcuts.
@MainActor
public enum GlobalShortcuts {
    public static func onTogglePanel(_ action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .togglePanel, action: action)
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

    public static func setRailShortcuts(first: Bool, second: Bool) {
        for (name, claimed) in [(KeyboardShortcuts.Name.stackToFirst, first), (.stackToSecond, second)] {
            if claimed { KeyboardShortcuts.enable(name) } else { KeyboardShortcuts.disable(name) }
        }
    }
}
