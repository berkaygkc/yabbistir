import AppKit
import CoreGraphics
import Foundation
import Testing
import YabCore
@testable import YabPasteboard

final class FakeWriter: PasteboardWriting {
    var writes: [(items: [[PasteboardRepresentation]], plainTextOnly: Bool)] = []
    func write(_ items: [[PasteboardRepresentation]], plainTextOnly: Bool) -> Int {
        writes.append((items, plainTextOnly))
        return 42
    }
}

final class FakePoster: KeystrokePosting {
    var posts: [(PasteKeystroke, CGKeyCode)] = []
    func post(_ keystroke: PasteKeystroke, keyCode: CGKeyCode) { posts.append((keystroke, keyCode)) }
}

let usLayout = KeyCodeResolver { $0 == 9 ? "v" : nil }

@Suite struct KeyCodeResolverTests {
    @Test func resolvesUSLayout() {
        #expect(usLayout.keyCode(for: "v") == 9)
    }

    @Test func resolvesNonQWERTYLayout() {
        let layout = KeyCodeResolver { [47: "v", 9: "ü"][$0] }
        #expect(layout.keyCode(for: "v") == 47)
    }

    @Test func unresolvableReturnsNil() {
        #expect(KeyCodeResolver { _ in nil }.keyCode(for: "v") == nil)
    }
}

@Suite struct PasteRulesTests {
    @Test func terminalImageUsesControlV() {
        #expect(PasteRules.keystroke(targetBundleID: "com.apple.Terminal", kind: .image) == .controlV)
    }

    @Test func terminalTextUsesCommandV() {
        #expect(PasteRules.keystroke(targetBundleID: "com.mitchellh.ghostty", kind: .text) == .commandV)
    }

    @Test func otherAppImageUsesCommandV() {
        #expect(PasteRules.keystroke(targetBundleID: "com.apple.Safari", kind: .image) == .commandV)
    }

    @Test func unknownTargetUsesCommandV() {
        #expect(PasteRules.keystroke(targetBundleID: nil, kind: .image) == .commandV)
    }
}

@MainActor @Suite struct PasterTests {
    let writer = FakeWriter()
    let poster = FakePoster()
    let items = [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("merhaba".utf8))]]

    func paster(trusted: Bool, secureInput: Bool = false, resolver: KeyCodeResolver = usLayout,
                didWrite: @escaping (Int) -> Void = { _ in }) -> Paster {
        Paster(writer: writer, resolver: resolver, poster: poster, isTrusted: { trusted }, isSecureInput: { secureInput }, didWrite: didWrite)
    }

    @Test func secureKeyboardEntryCopiesOnly() async {
        let outcome = await paster(trusted: true, secureInput: true)
            .paste(items, kind: .text, targetBundleID: "com.apple.Terminal", plainText: false)
        #expect(outcome == .copiedOnly(.secureInput))
        #expect(poster.posts.isEmpty)
        #expect(writer.writes.count == 1)
    }

    /// A secret from a source is pasted into password fields, which turn Secure Event Input on; its paste sends
    /// ⌘V there anyway, over a clipboard it wrote itself.
    @Test func sendCanIgnoreSecureInput() async {
        let outcome = await paster(trusted: true, secureInput: true)
            .send(kind: .text, targetBundleID: "com.apple.Safari", honorsSecureInput: false)
        #expect(outcome == .pasted)
        #expect(poster.posts.count == 1)
        #expect(writer.writes.isEmpty)
    }

    @Test func trustedPostsCommandV() async {
        let outcome = await paster(trusted: true).paste(items, kind: .text, targetBundleID: "com.apple.TextEdit", plainText: false)
        #expect(outcome == .pasted)
        #expect(poster.posts.count == 1)
        #expect(poster.posts.first?.0 == .commandV)
        #expect(poster.posts.first?.1 == 9)
    }

    @Test func untrustedCopiesOnly() async {
        let outcome = await paster(trusted: false).paste(items, kind: .text, targetBundleID: nil, plainText: false)
        #expect(outcome == .copiedOnly(.accessibilityDenied))
        #expect(poster.posts.isEmpty)
        #expect(writer.writes.count == 1)
    }

    @Test func unresolvableKeyCopiesOnly() async {
        let outcome = await paster(trusted: true, resolver: KeyCodeResolver { _ in nil })
            .paste(items, kind: .text, targetBundleID: nil, plainText: false)
        #expect(outcome == .copiedOnly(.keyNotResolvable))
        #expect(poster.posts.isEmpty)
    }

    @Test func didWriteReceivesChangeCount() async {
        var seen: [Int] = []
        _ = await paster(trusted: true, didWrite: { seen.append($0) }).paste(items, kind: .text, targetBundleID: nil, plainText: false)
        #expect(seen == [42])
    }

    @Test func plainTextWritesOnlyPlainText() async {
        _ = await paster(trusted: true).paste(items, kind: .text, targetBundleID: nil, plainText: true)
        #expect(writer.writes.first?.plainTextOnly == true)
    }

    /// A finished job pastes only into the app it was started for. The person can switch apps in
    /// the beat before ⌘V; then the result stays on the clipboard and no keystroke is sent.
    @Test func aTargetThatLeftDuringTheBeatGetsNoCommandV() async {
        let inFront = Flag(true)
        let paster = paster(trusted: true)
        let paste = Task { await paster.paste(items, kind: .text, targetBundleID: "com.apple.finder", plainText: false,
                                              onlyIf: { inFront.value }) }
        // The clipboard is written first; the switch comes during the wait that follows.
        while writer.writes.isEmpty { await Task.yield() }
        inFront.value = false
        #expect(await paste.value == .copiedOnly(.targetLeft))
        #expect(poster.posts.isEmpty)
        #expect(writer.writes.count == 1)
    }

    /// The panel's own paste asks the same question as a job: when the front app is not the one
    /// the panel opened over (or the panel is back), ⌘V is never sent. This test sits beside the
    /// job one above: it covers a check that fails before the clipboard write is even waited on.
    @Test func thePanelNeverPastesIntoAnotherApp() async {
        let outcome = await paster(trusted: true).paste(items, kind: .text, targetBundleID: "com.apple.finder", plainText: false,
                                                        onlyIf: { false })
        #expect(outcome == .copiedOnly(.targetLeft))
        #expect(poster.posts.isEmpty)
        #expect(writer.writes.count == 1)
    }

    @Test func aTargetStillInFrontIsPasted() async {
        let outcome = await paster(trusted: true).paste(items, kind: .text, targetBundleID: "com.apple.finder", plainText: false,
                                                        onlyIf: { true })
        #expect(outcome == .pasted)
        #expect(poster.posts.count == 1)
    }
}

@MainActor final class Flag {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

@Suite struct SystemPasteboardWriterTests {
    @Test func plainPasteOfItemWithoutTextWritesTheItem() {
        let board = NSPasteboard(name: NSPasteboard.Name("yab-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        SystemPasteboardWriter(pasteboard: board)
            .write([[PasteboardRepresentation(type: TypeIdentifiers.png, data: png)]], plainTextOnly: true)
        #expect(board.data(forType: .png) == png)
    }
}

@MainActor @Suite struct SystemCleanWriterTests {
    /// A capture rule's clean copy goes back only over the copy it came from, and the monitor lets the write pass.
    @Test func writesOnlyOverTheSameCopy() {
        let board = NSPasteboard(name: NSPasteboard.Name("yab-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var ignored: [Int] = []
        let writer = SystemCleanWriter(pasteboard: board) { ignored.append($0) }
        let clean = [[rep(TypeIdentifiers.url, "https://a.dev/x"), rep(TypeIdentifiers.plainText, "https://a.dev/x")]]

        board.clearContents()
        board.setString("https://a.dev/x?utm_source=news", forType: .string)
        let copied = board.changeCount
        board.clearContents()
        board.setString("newer", forType: .string)
        #expect(!writer.writeIfUnchanged(clean, expected: copied))
        #expect(board.string(forType: .string) == "newer")
        #expect(ignored.isEmpty)

        #expect(writer.writeIfUnchanged(clean, expected: board.changeCount))
        #expect(board.string(forType: .string) == "https://a.dev/x")
        #expect(board.data(forType: NSPasteboard.PasteboardType(TypeIdentifiers.url)) == Data("https://a.dev/x".utf8))
        #expect(ignored == [board.changeCount])
    }
}

@Suite struct SystemLayoutTests {
    /// Integration check: the real Carbon layout lookup finds a key for "v" on this Mac.
    @Test func currentASCIICapableResolvesV() {
        #expect(KeyCodeResolver.currentASCIICapable().keyCode(for: "v") != nil)
    }
}
