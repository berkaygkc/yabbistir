import CoreGraphics
import Testing
import YabPasteboard
@testable import YabStack

/// Only the user's own ⌘V advances the stack.
@Suite struct PasteKeyTapTests {
    @Test func aUserCommandVIsAPaste() {
        #expect(PasteKeyTap.isUserPaste(keyCode: 9, flags: .maskCommand, userData: 0, pasteKeyCode: 9))
    }

    @Test func yabbistirsOwnKeystrokeIsNot() {
        #expect(!PasteKeyTap.isUserPaste(keyCode: 9, flags: .maskCommand, userData: SyntheticEvent.marker, pasteKeyCode: 9))
    }

    @Test func otherChordsAreNot() {
        #expect(!PasteKeyTap.isUserPaste(keyCode: 9, flags: [.maskCommand, .maskShift], userData: 0, pasteKeyCode: 9))
        #expect(!PasteKeyTap.isUserPaste(keyCode: 9, flags: [], userData: 0, pasteKeyCode: 9))
        #expect(!PasteKeyTap.isUserPaste(keyCode: 8, flags: .maskCommand, userData: 0, pasteKeyCode: 9))
    }

    @Test func thePasteKeyFollowsTheLayout() {
        #expect(PasteKeyTap.isUserPaste(keyCode: 47, flags: .maskCommand, userData: 0, pasteKeyCode: 47))
    }
}
