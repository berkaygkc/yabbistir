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
