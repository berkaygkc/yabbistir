import KeyboardShortcuts
import Testing
@testable import YabPlatform

@Suite struct GlobalShortcutTests {
    @Test func everyUserShortcutHasItsDefault() {
        #expect(GlobalShortcut.allCases == [.togglePanel, .stackCopy])
        #expect(GlobalShortcut.togglePanel.name.defaultShortcut == .init(.v, modifiers: [.command, .shift]))
        #expect(GlobalShortcut.stackCopy.name.defaultShortcut == .init(.c, modifiers: [.command, .shift]))
    }
}
