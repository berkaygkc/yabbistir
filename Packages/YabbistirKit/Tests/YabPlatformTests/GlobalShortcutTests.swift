import KeyboardShortcuts
import Testing
@testable import YabPlatform

@Suite struct GlobalShortcutTests {
    @Test func everyUserShortcutHasItsDefault() {
        #expect(GlobalShortcut.allCases == [.togglePanel, .stackCopy])
        #expect(GlobalShortcut.togglePanel.name.defaultShortcut == .init(.v, modifiers: [.command, .shift]))
        #expect(GlobalShortcut.stackCopy.name.defaultShortcut == .init(.c, modifiers: [.command, .shift]))
    }

    /// The first-run window shows the panel's shortcut as one keycap per key, modifiers first.
    @MainActor @Test func keycapsSplitAShortcutIntoKeys() {
        #expect(GlobalShortcut.keycaps(for: .init(.v, modifiers: [.command, .shift])) == ["⇧", "⌘", "V"])
        #expect(GlobalShortcut.keycaps(for: .init(.space, modifiers: [.option])).first == "⌥")
        #expect(GlobalShortcut.keycaps(for: .init(.space, modifiers: [.option])).count == 2)
        #expect(GlobalShortcut.keycaps(for: nil).isEmpty)
    }
}
