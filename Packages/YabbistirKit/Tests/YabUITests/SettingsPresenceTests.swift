import Testing
@testable import YabUI

@MainActor @Suite struct SettingsPresenceTests {
    @Test func followsTheWindow() {
        let presence = SettingsPresence()
        #expect(!presence.isVisible)
        presence.shown()
        #expect(presence.isVisible)
        presence.closed()
        #expect(!presence.isVisible)
    }

    @Test func comingForwardIsCounted() {
        let presence = SettingsPresence()
        presence.cameForward()
        presence.cameForward()
        #expect(presence.forwardCount == 2)
    }

    @Test func aMiniaturizedWindowIsNotVisible() {
        let presence = SettingsPresence()
        presence.shown()
        presence.miniaturized()
        #expect(!presence.isVisible)
        presence.deminiaturized()
        #expect(presence.isVisible)
    }
}
