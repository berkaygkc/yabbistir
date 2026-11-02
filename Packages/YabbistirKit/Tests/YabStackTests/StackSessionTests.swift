import Foundation
import Testing
import YabCore
import YabPasteboard
@testable import YabStack

/// Records what the session puts on the clipboard.
final class FakeWriter: PasteboardWriting {
    var writes: [[[PasteboardRepresentation]]] = []
    /// The `plainTextOnly` flag of each write.
    var plainFlags: [Bool] = []
    /// The clipboard's change count.
    private(set) var count = 0

    /// Something other than the stack changed the clipboard (a skipped copy, a snippet tool).
    func externalChange() { count += 1 }

    func write(_ items: [[PasteboardRepresentation]], plainTextOnly: Bool) -> Int {
        writes.append(items)
        plainFlags.append(plainTextOnly)
        count += 1
        return count
    }

    var lastText: String? {
        writes.last?.first?.first { $0.type == TypeIdentifiers.plainText }.map { String(decoding: $0.data, as: UTF8.self) }
    }
}

/// The ⌘V keystrokes the session replays, with what the clipboard held at that moment.
@MainActor final class Replays {
    var texts: [String?] = []
}

/// Polls a condition (timers run on the main actor; parallel suites can delay them).
@MainActor func waitUntil(_ condition: () -> Bool) async throws {
    let start = ContinuousClock.now
    while !condition(), ContinuousClock.now - start < .seconds(5) {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

@MainActor @Suite struct StackSessionTests {
    let library: Library
    let writer = FakeWriter()
    let replays = Replays()
    let session: StackSession
    let ids: [Int64]

    /// Three text items, "bir", "iki" and "üç"; short timings.
    init() throws {
        library = try Library(store: ItemStore.temporary())
        var ids: [Int64] = []
        for (offset, text) in ["bir", "iki", "üç"].enumerated() {
            let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data(text.utf8))]],
                                    source: nil, device: .local, capturedAt: Date().addingTimeInterval(Double(offset)))
            let item = try #require(try library.store.ingest(clip)).item
            library.didIngest(item)
            ids.append(item.id!)
        }
        self.ids = ids
        session = StackSession(library: library, writer: writer, didWrite: { _ in },
                               changeCount: { [writer] in writer.count },
                               replayPaste: { [writer, replays] in replays.texts.append(writer.lastText) },
                               timing: StackTiming(rail: .milliseconds(80), settle: .milliseconds(10), closeDelay: .milliseconds(20)))
    }

    /// With "always plain text" on, the stack puts the plain text alone on the clipboard.
    @Test func alwaysPlainTextWritesPlainOnly() throws {
        let plainSession = StackSession(library: library, writer: writer, didWrite: { _ in }, plainText: { true })
        plainSession.append(ids[0])
        #expect(writer.plainFlags == [true])
        session.append(ids[1])
        #expect(writer.plainFlags == [true, false])
    }

    /// A ⌘V of something the stack did not put on the clipboard (a password manager's copy,
    /// a snippet) pastes that, not the head: the head stays and goes back on the clipboard.
    @Test func aPasteOfSomethingElseKeepsTheHead() async throws {
        session.append(ids[0])
        session.append(ids[1])
        writer.externalChange()
        session.userPasted()
        try await waitUntil { writer.writes.count == 3 }
        #expect(session.entries.map(\.itemID) == [ids[0], ids[1]])
        #expect(writer.lastText == "bir")
    }

    /// Once the rail's copy is next, the rail and ⌥1/⌥2 are gone (they type characters again).
    @Test func theRailLeavesOnceItsCopyIsNext() async throws {
        session.append(ids[0])
        session.append(ids[1])
        #expect(session.isRailVisible)
        session.userPasted()
        try await waitUntil { session.entries.count == 1 }
        #expect(!session.isRailVisible)
        #expect(!session.wantsRailShortcuts)
    }

    /// ⌥2 is claimed only when it would move the copy: a third item, and the copy not already second.
    @Test func secondPlaceIsOfferedOnlyWhenItMovesTheCopy() {
        session.append(ids[0])
        session.append(ids[1])
        #expect(session.isRailVisible)
        #expect(!session.offersSecondPlace)
        session.append(ids[2])
        #expect(session.offersSecondPlace)
    }

    /// An item deleted from the library leaves the stack instead of staying as an empty row.
    @Test func aDeletedItemLeavesTheStack() {
        session.append(ids[0])
        session.append(ids[1])
        session.append(ids[0])
        session.itemDeleted(ids[0])
        #expect(session.entries.map(\.itemID) == [ids[1]])
        #expect(writer.lastText == "iki")
    }

    /// ⌘⇧C with nothing selected opens an empty stack; copies made from then on (a page's copy
    /// button, say) line up in it.
    @Test func anEmptyStackStaysOpenUntilTheFirstCopy() async throws {
        session.open()
        #expect(session.isOpen)
        #expect(session.entries.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.isOpen)
        session.userPasted()
        session.append(ids[0])
        #expect(session.entries.map(\.itemID) == [ids[0]])
        #expect(writer.lastText == "bir")
    }

    @Test func firstCopyOpensTheStackWithoutARail() {
        session.append(ids[0])
        #expect(session.isOpen)
        #expect(session.entries.map(\.itemID) == [ids[0]])
        #expect(!session.isRailVisible)
        #expect(writer.lastText == "bir")
    }
    @Test func laterCopiesQueueAndTheHeadStaysOnTheClipboard() {
        session.append(ids[0]); session.append(ids[1])
        #expect(session.entries.map(\.itemID) == [ids[0], ids[1]])
        #expect(session.recentEntryID == session.entries[1].id)
        #expect(writer.lastText == "bir")
    }
    @Test func theRailAndItsShortcutsExpire() async throws {
        session.append(ids[0]); session.append(ids[1])
        #expect(session.wantsRailShortcuts)
        try await waitUntil { !session.wantsRailShortcuts }
    }
    @Test func optionOneMovesTheRecentCopyToTheTop() {
        session.append(ids[0]); session.append(ids[1]); session.append(ids[2])
        session.moveRecent(to: 0)
        #expect(session.entries.map(\.itemID) == [ids[2], ids[0], ids[1]])
        #expect(writer.lastText == "üç")
        #expect(!session.isRailVisible)
    }
    @Test func optionTwoMovesItSecond() {
        session.append(ids[0]); session.append(ids[1]); session.append(ids[2])
        session.moveRecent(to: 1)
        #expect(session.entries.map(\.itemID) == [ids[0], ids[2], ids[1]])
        #expect(writer.lastText == "bir")
    }
    /// The head leaves the moment ⌘V is pressed; it stays on the clipboard until the target has
    /// read it, then the next one takes its place.
    @Test func aPasteLeavesTheStackTheMomentItIsPressed() async throws {
        session.append(ids[0]); session.append(ids[1])
        #expect(session.userPasted())
        #expect(session.entries.map(\.itemID) == [ids[1]])
        #expect(writer.lastText == "bir")
        try await waitUntil { writer.lastText == "iki" }
    }

    /// User test: quick ⌘Vs paste one item each, in order. A ⌘V pressed while the previous paste
    /// settles is held and replayed once its own item is on the clipboard.
    @Test func quickPastesEachTakeTheNextItem() async throws {
        session.append(ids[0]); session.append(ids[1]); session.append(ids[2])
        #expect(session.userPasted())
        #expect(session.userPasted() == false)
        #expect(session.entries.map(\.itemID) == [ids[2]])
        try await waitUntil { replays.texts.count == 1 }
        #expect(replays.texts == ["iki"])
        try await waitUntil { writer.lastText == "üç" }
        #expect(replays.texts.count == 1)
    }

    /// Holding ⌘V down repeats the key; the repeats are held and never drain the stack.
    @Test func aHeldDownCommandVDoesNotDrainTheStack() {
        session.append(ids[0]); session.append(ids[1]); session.append(ids[2])
        session.userPasted()
        #expect(session.userPasted(isRepeat: true) == false)
        #expect(session.entries.map(\.itemID) == [ids[1], ids[2]])
    }

    /// A tap that can only listen cannot hold a ⌘V: it goes through and the stack does not count it.
    @Test func aListenOnlyTapDoesNotHold() {
        session.append(ids[0]); session.append(ids[1]); session.append(ids[2])
        session.userPasted(canHold: false)
        #expect(session.userPasted(canHold: false))
        #expect(session.entries.map(\.itemID) == [ids[1], ids[2]])
    }
    @Test func theLastPasteClosesTheStack() async throws {
        session.append(ids[0])
        session.userPasted()
        try await waitUntil { !session.isOpen }
        #expect(session.entries.isEmpty)
    }
    @Test func removingOrMovingTheHeadRewritesTheClipboard() {
        session.append(ids[0]); session.append(ids[1]); session.append(ids[2])
        session.remove(entryID: session.entries[0].id)
        #expect(writer.lastText == "iki")
        session.move(entryID: session.entries[1].id, to: 0)
        #expect(writer.lastText == "üç")
    }
    @Test func theSameItemCanBeQueuedTwice() {
        session.append(ids[0]); session.append(ids[0])
        #expect(session.entries.count == 2)
        #expect(session.entries[0].id != session.entries[1].id)
    }
    @Test func restoreHeadPutsItBackAfterAnotherPaste() {
        session.append(ids[0]); session.append(ids[1])
        writer.writes.removeAll()
        session.restoreHead()
        #expect(writer.lastText == "bir")
    }
    @Test func finishClosesAndClears() {
        session.append(ids[0]); session.append(ids[1])
        session.finish()
        #expect(!session.isOpen && session.entries.isEmpty && !session.isRailVisible)
    }
}
