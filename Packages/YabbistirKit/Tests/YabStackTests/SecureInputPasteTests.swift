import Testing
@testable import YabStack

/// What the relay did: its claims on ⌘V, and each ⌘V it typed with whether ⌘V was claimed at that moment.
@MainActor final class RelayRecord {
    var secure = false
    var claims: [Bool] = []
    var typedWhileClaimed: [Bool] = []
    var relay: SecureInputPaste!

    init() {
        relay = SecureInputPaste(isSecureInput: { [unowned self] in secure }, claim: { [unowned self] in claims.append($0) },
                                 type: { [unowned self] in typedWhileClaimed.append(relay.claimed) },
                                 interval: .milliseconds(5), rearm: .milliseconds(30))
    }
}

/// Secure input hides keystrokes from the Sıra's tap; while it is on and the Sıra is open, ⌘V is claimed instead.
@MainActor @Suite struct SecureInputPasteTests {
    @Test func commandVIsClaimedOnlyWhileSecureInputIsOn() async throws {
        let record = RelayRecord()
        record.relay.start()
        try await Task.sleep(for: .milliseconds(30))
        #expect(record.claims.isEmpty)

        record.secure = true
        try await waitUntil { record.relay.claimed }
        record.secure = false
        try await waitUntil { !record.relay.claimed }
        #expect(record.claims == [true, false])
    }

    @Test func closingTheSıraLetsGo() async throws {
        let record = RelayRecord()
        record.secure = true
        record.relay.start()
        #expect(record.relay.claimed, "claimed at once when the Sıra opens")
        record.relay.stop()
        #expect(!record.relay.claimed)
        try await Task.sleep(for: .milliseconds(30))
        #expect(record.claims == [true, false], "no longer watching")
    }

    /// The typed ⌘V must reach the app, not the claim: it is let go while typing and taken back after.
    @Test func typingLetsGoOfTheClaimAndTakesItBack() async throws {
        let record = RelayRecord()
        record.secure = true
        record.relay.start()
        record.relay.typePaste()
        #expect(record.typedWhileClaimed == [false])
        #expect(record.claims == [true, false])
        try await waitUntil { record.relay.claimed }
        #expect(record.claims == [true, false, true])
    }

    @Test func typingWithoutAClaimJustTypes() {
        let record = RelayRecord()
        record.relay.typePaste()
        #expect(record.typedWhileClaimed == [false])
        #expect(record.claims.isEmpty)
    }

    @Test func aPressUnderSecureInputIsCountedByTheSıra() {
        let record = RelayRecord()
        record.secure = true
        record.relay.start()
        var counted = 0
        record.relay.pressed(ownWindowKey: false) { counted += 1; return true }
        #expect(counted == 1)
        #expect(record.typedWhileClaimed.count == 1)

        // Held by the Sıra (a press during its pause): typed later, by its replay.
        record.relay.pressed(ownWindowKey: false) { counted += 1; return false }
        #expect(counted == 2)
        #expect(record.typedWhileClaimed.count == 1)
    }

    /// Secure input just went off: the tap heard this ⌘V and counted it; it is only typed again.
    @Test func aPressAfterSecureInputWentOffIsOnlyTyped() {
        let record = RelayRecord()
        record.secure = true
        record.relay.start()
        record.secure = false
        var counted = 0
        record.relay.pressed(ownWindowKey: false) { counted += 1; return true }
        #expect(counted == 0)
        #expect(record.typedWhileClaimed.count == 1)
    }

    /// ⌘V into yabbistir's own window (the panel's search field) pastes there and is no paste of the Sıra's.
    @Test func aPressIntoYabbistirsOwnWindowIsNotCounted() {
        let record = RelayRecord()
        record.secure = true
        record.relay.start()
        var counted = 0
        record.relay.pressed(ownWindowKey: true) { counted += 1; return true }
        #expect(counted == 0)
        #expect(record.typedWhileClaimed.count == 1)
    }

    @Test func closingWhileTypingKeepsItLetGo() async throws {
        let record = RelayRecord()
        record.secure = true
        record.relay.start()
        record.relay.typePaste()
        record.relay.stop()
        try await Task.sleep(for: .milliseconds(60))
        #expect(!record.relay.claimed)
        #expect(record.claims == [true, false])
    }
}
