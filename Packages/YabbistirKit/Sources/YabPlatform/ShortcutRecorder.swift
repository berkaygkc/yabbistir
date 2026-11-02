import KeyboardShortcuts
import SwiftUI

/// A global shortcut the person can change in Settings.
public enum GlobalShortcut: CaseIterable, Sendable {
    case togglePanel, stackCopy

    var name: KeyboardShortcuts.Name {
        switch self {
        case .togglePanel: .togglePanel
        case .stackCopy: .stackCopy
        }
    }

    /// The shortcut as it is set now, one keycap legend per key: ["⇧", "⌘", "V"]. Empty when it is turned off.
    @MainActor public var keycaps: [String] {
        Self.keycaps(for: KeyboardShortcuts.getShortcut(for: name))
    }

    @MainActor static func keycaps(for shortcut: KeyboardShortcuts.Shortcut?) -> [String] {
        guard let shortcut else { return [] }
        let modifiers = shortcut.modifiers.ks_symbolicRepresentation
        return modifiers.map(String.init) + [String(shortcut.description.dropFirst(modifiers.count))]
    }
}

/// Records one global shortcut. The library warns about combinations the system or the menus already use.
public struct ShortcutRecorder: View {
    private let shortcut: GlobalShortcut

    public init(_ shortcut: GlobalShortcut) {
        self.shortcut = shortcut
    }

    public var body: some View {
        KeyboardShortcuts.Recorder(for: shortcut.name)
    }
}
