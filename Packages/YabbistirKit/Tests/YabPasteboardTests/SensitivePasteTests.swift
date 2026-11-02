import AppKit
import Foundation
import Testing
import YabCore
@testable import YabPasteboard

/// A clipboard in memory; every write moves its change count, like the real one.
final class FakeSensitiveBoard: SensitivePasteboard {
    var changeCount = 7
    var items: [[PasteboardRepresentation]]
    var writes: [(text: String, concealed: Bool)] = []
    var restores: [[[PasteboardRepresentation]]] = []
    var snapshots = 0

    init(_ items: [[PasteboardRepresentation]]) { self.items = items }

    func snapshot() -> [[PasteboardRepresentation]] {
        snapshots += 1
        return items
    }

    func write(_ text: String, concealed: Bool) -> Int {
        writes.append((text, concealed))
        return put([[rep(TypeIdentifiers.plainText, text)]])
    }

    func restore(_ items: [[PasteboardRepresentation]]) -> Int {
        restores.append(items)
        return put(items)
    }

    /// Another app (or the person) copies something.
    func copyElsewhere(_ text: String) { _ = put([[rep(TypeIdentifiers.plainText, text)]]) }

    private func put(_ items: [[PasteboardRepresentation]]) -> Int {
        self.items = items
        changeCount += 1
        return changeCount
    }
}

/// Waits are real but short; the one a test must not take is an hour, so taking it runs into the time limit.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SensitivePasteTests {
    static let soon: Duration = .milliseconds(10)
    static let never: Duration = .seconds(3600)
    static let concealed = "org.nspasteboard.ConcealedType"
    static let transient = "org.nspasteboard.TransientType"
    static let source = "org.nspasteboard.source"

    let previous = [[rep(TypeIdentifiers.plainText, "önceki")]]
    let secret = [[rep(TypeIdentifiers.plainText, "s3cr3t-örnek")]]

    func sensitivePaste(_ board: SensitivePasteboard, outcome: PasteOutcome = .pasted, restoreDelay: Duration = soon,
                        copiedOnlyLifetime: Duration = never, didWrite: @escaping (Int) -> Void = { _ in }) -> SensitivePaste {
        SensitivePaste(board: board, send: { _, _ in outcome }, didWrite: didWrite,
                       restoreDelay: restoreDelay, copiedOnlyLifetime: copiedOnlyLifetime)
    }

    func pasteSecret(_ paste: SensitivePaste, _ text: String = "s3cr3t-örnek",
                     restoreInstead: (() -> Void)? = nil) async -> PasteOutcome {
        await paste.paste(text, concealed: true, targetBundleID: "com.apple.Safari", onlyIf: nil, restoreInstead: restoreInstead)
    }

    static func privateBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("yab-tests-\(UUID().uuidString)"))
    }

    static func types(_ board: NSPasteboard) -> Set<String> {
        Set((board.types ?? []).map(\.rawValue))
    }

    @Test func aSecretIsWrittenConcealedTransientAndTagged() {
        let board = Self.privateBoard()
        defer { board.releaseGlobally() }
        let system = SystemSensitivePasteboard(pasteboard: board, sourceID: "dev.yabbistir.app")

        let written = system.write("s3cr3t-örnek", concealed: true)
        #expect(written == board.changeCount)
        #expect(system.changeCount == board.changeCount)
        #expect(board.pasteboardItems?.count == 1)
        let types = Self.types(board)
        #expect(types.isSuperset(of: [TypeIdentifiers.plainText, Self.concealed, Self.transient, Self.source]))
        #expect(board.string(forType: .string) == "s3cr3t-örnek")
        #expect(board.data(forType: NSPasteboard.PasteboardType(Self.source)) == Data("dev.yabbistir.app".utf8))
        // The app's own monitor skips it too.
        #expect(CaptureFilter().evaluate(types: types, source: nil) == .skip(.concealed))

        _ = system.write("deniz.k", concealed: false)
        let textTypes = Self.types(board)
        #expect(!textTypes.contains(Self.concealed))
        #expect(textTypes.isSuperset(of: [TypeIdentifiers.plainText, Self.transient, Self.source]))
        #expect(board.string(forType: .string) == "deniz.k")
    }

    /// Every type of the item that was there goes back as it was, a while after ⌘V.
    @Test func afterAPasteThePreviousClipboardComesBack() async {
        let board = Self.privateBoard()
        defer { board.releaseGlobally() }
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("https://ornek.dev/giris", forType: .string)
        item.setData(Data("https://ornek.dev/giris".utf8), forType: NSPasteboard.PasteboardType(TypeIdentifiers.url))
        board.writeObjects([item])
        let before = SystemPasteboardReader(pasteboard: board).readItems()
        let paste = sensitivePaste(SystemSensitivePasteboard(pasteboard: board, sourceID: "dev.yabbistir.app"))

        #expect(await pasteSecret(paste) == .pasted)
        #expect(board.string(forType: .string) == "s3cr3t-örnek")
        await paste.pendingRestore?.value
        #expect(SystemPasteboardReader(pasteboard: board).readItems() == before)
        #expect(!Self.types(board).contains(Self.concealed))
        #expect(paste.pendingRestore == nil)
    }

    @Test func aNewerCopyIsNeverOverwritten() async {
        let board = FakeSensitiveBoard(previous)
        let paste = sensitivePaste(board)
        _ = await pasteSecret(paste)
        board.copyElsewhere("yeni kopya")
        await paste.pendingRestore?.value
        #expect(board.restores.isEmpty)
        #expect(board.items == [[rep(TypeIdentifiers.plainText, "yeni kopya")]])
    }

    /// Nothing was pasted, so the secret has no reason to stay.
    @Test func aTargetThatLeftGetsTheClipboardBackAtOnce() async {
        let board = FakeSensitiveBoard(previous)
        let paste = sensitivePaste(board, outcome: .copiedOnly(.targetLeft), restoreDelay: Self.never)
        #expect(await pasteSecret(paste) == .copiedOnly(.targetLeft))
        #expect(board.items == previous)
        #expect(board.restores.count == 1)
        #expect(paste.pendingRestore == nil)
    }

    /// Left on the clipboard for the person to press ⌘V, it stays its lifetime and then goes.
    @Test(arguments: [CopiedOnlyReason.accessibilityDenied, .keyNotResolvable, .secureInput])
    func aCopyOnlySecretLeavesAfterItsLifetime(reason: CopiedOnlyReason) async {
        let board = FakeSensitiveBoard(previous)
        let paste = sensitivePaste(board, outcome: .copiedOnly(reason), restoreDelay: Self.never, copiedOnlyLifetime: Self.soon)
        #expect(await pasteSecret(paste) == .copiedOnly(reason))
        #expect(board.items == secret)
        await paste.pendingRestore?.value
        #expect(board.items == previous)
    }

    @Test func anEmptyPreviousClipboardIsCleared() async {
        let board = Self.privateBoard()
        defer { board.releaseGlobally() }
        board.clearContents()
        let paste = sensitivePaste(SystemSensitivePasteboard(pasteboard: board, sourceID: "dev.yabbistir.app"))

        _ = await pasteSecret(paste)
        #expect(board.pasteboardItems?.count == 1)
        await paste.pendingRestore?.value
        #expect(board.pasteboardItems?.isEmpty ?? true)
        #expect(board.string(forType: .string) == nil)
    }

    /// The second secret's clipboard is the first secret; what comes back is what was there before both.
    @Test func twoQuickSecretsRestoreTheOriginalClipboard() async {
        let board = FakeSensitiveBoard(previous)
        let paste = sensitivePaste(board, restoreDelay: .milliseconds(200))
        _ = await pasteSecret(paste)
        let first = paste.pendingRestore
        _ = await pasteSecret(paste, "ikinci-s3cr3t")
        #expect(first?.isCancelled == true)
        #expect(board.snapshots == 1)
        await paste.pendingRestore?.value
        #expect(board.items == previous)
        #expect(board.restores.count == 1)
    }

    /// A copy made between two secrets is the clipboard the second one gives back; the older one is gone.
    @Test func aCopyBetweenTwoSecretsIsWhatComesBack() async {
        let board = FakeSensitiveBoard(previous)
        let paste = sensitivePaste(board, restoreDelay: .milliseconds(200))
        _ = await pasteSecret(paste)
        board.copyElsewhere("yeni kopya")
        _ = await pasteSecret(paste, "ikinci-s3cr3t")
        await paste.pendingRestore?.value
        #expect(board.items == [[rep(TypeIdentifiers.plainText, "yeni kopya")]])
        #expect(board.restores.count == 1)
    }

    /// The screen locks or the app quits: the secret leaves the clipboard then, not when its timer would end.
    @Test func flushRestoresAPendingSecretNow() async {
        let board = FakeSensitiveBoard(previous)
        let paste = sensitivePaste(board, restoreDelay: Self.never)
        _ = await pasteSecret(paste)
        let timer = paste.pendingRestore
        paste.flush()
        #expect(board.items == previous)
        #expect(timer?.isCancelled == true)
        #expect(paste.pendingRestore == nil)
        paste.flush()
        #expect(board.restores.count == 1)
    }

    /// A username from a source: transient and local, but it stays on the clipboard and nothing comes back.
    @Test func textIsTransientAndStays() async {
        let board = Self.privateBoard()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("önceki", forType: .string)
        var sent: [String?] = []
        let paste = SensitivePaste(board: SystemSensitivePasteboard(pasteboard: board, sourceID: "dev.yabbistir.app"),
                                   send: { target, _ in sent.append(target); return .pasted }, didWrite: { _ in },
                                   restoreDelay: Self.soon, copiedOnlyLifetime: Self.soon)

        #expect(await paste.paste("deniz.k", concealed: false, targetBundleID: "com.apple.Safari", onlyIf: nil, restoreInstead: nil) == .pasted)
        #expect(sent == ["com.apple.Safari"])
        #expect(paste.pendingRestore == nil)
        let types = Self.types(board)
        #expect(types.contains(Self.transient))
        #expect(!types.contains(Self.concealed))
        paste.flush()
        #expect(board.string(forType: .string) == "deniz.k")
    }

    /// The clipboard moves on in the beat before ⌘V (a flush, another value, a copy from another device): the
    /// keystroke is not sent, so what took the value's place is never pasted.
    @Test(arguments: [true, false])
    func noKeystrokeOnceTheClipboardMovedOn(concealed: Bool) async {
        let board = FakeSensitiveBoard(previous)
        let paste = SensitivePaste(board: board, send: { _, onlyIf in
            board.copyElsewhere("yeni kopya")
            return onlyIf?() ?? true ? .pasted : .copiedOnly(.targetLeft)
        }, didWrite: { _ in }, restoreDelay: Self.soon, copiedOnlyLifetime: Self.never)
        let outcome = await paste.paste("s3cr3t-örnek", concealed: concealed, targetBundleID: "com.apple.Safari", onlyIf: nil,
                                        restoreInstead: nil)
        #expect(outcome == .copiedOnly(.targetLeft))
        #expect(board.items == [[rep(TypeIdentifiers.plainText, "yeni kopya")]])
        #expect(board.restores.isEmpty)
    }

    /// While the clipboard holds the value, ⌘V goes; the caller's own check still decides.
    @Test(arguments: [true, false])
    func theKeystrokeStillAsksTheCaller(concealed: Bool) async {
        let board = FakeSensitiveBoard(previous)
        let paste = SensitivePaste(board: board, send: { _, onlyIf in onlyIf?() ?? true ? .pasted : .copiedOnly(.targetLeft) },
                                   didWrite: { _ in }, restoreDelay: Self.soon, copiedOnlyLifetime: Self.never)
        #expect(await paste.paste("s3cr3t-örnek", concealed: concealed, targetBundleID: nil, onlyIf: nil, restoreInstead: nil) == .pasted)
        #expect(await paste.paste("s3cr3t-örnek", concealed: concealed, targetBundleID: nil, onlyIf: { true }, restoreInstead: nil) == .pasted)
        #expect(await paste.paste("s3cr3t-örnek", concealed: concealed, targetBundleID: nil, onlyIf: { false }, restoreInstead: nil)
                == .copiedOnly(.targetLeft))
    }

    /// ⌘C on a source row: the text is written and nothing is typed.
    @Test func aCopyIsWrittenAndNotSent() {
        let board = FakeSensitiveBoard(previous)
        var sent = 0
        let paste = SensitivePaste(board: board, send: { _, _ in sent += 1; return .pasted }, didWrite: { _ in })
        paste.copy("deniz.k")
        #expect(board.writes.map(\.text) == ["deniz.k"])
        #expect(board.writes.map(\.concealed) == [false])
        #expect(sent == 0)
        #expect(paste.pendingRestore == nil)
    }

    /// The monitor lets both the secret and the clipboard that comes back pass, so neither lands in history.
    @Test func everyWriteIsReportedToTheMonitor() async {
        let board = FakeSensitiveBoard(previous)
        var reported: [Int] = []
        let paste = sensitivePaste(board, didWrite: { reported.append($0) })
        _ = await pasteSecret(paste)
        let written = board.changeCount
        await paste.pendingRestore?.value
        #expect(reported == [written, board.changeCount])
        paste.copy("deniz.k")
        #expect(reported == [written, written + 1, board.changeCount])
    }

    /// With the paste stack open, the stack puts its own head back instead of the snapshot.
    @Test func theRestoreCanBeHandedToTheSira() async {
        let board = FakeSensitiveBoard(previous)
        var reported: [Int] = []
        var handed = 0
        let paste = sensitivePaste(board, didWrite: { reported.append($0) })
        // The Sıra puts its head back itself (and tells the monitor through its own writer).
        _ = await pasteSecret(paste, restoreInstead: { handed += 1; board.copyElsewhere("sıranın başı") })
        let written = board.changeCount
        await paste.pendingRestore?.value
        #expect(handed == 1)
        #expect(board.restores.isEmpty)
        #expect(reported == [written])
    }

    /// The Sıra finished while the secret waited, so it had no head to put back: the clipboard from before still comes
    /// back over the secret.
    @Test func aSiraWithNothingToPutBackStillTakesTheSecretAway() async {
        let board = FakeSensitiveBoard(previous)
        var reported: [Int] = []
        var handed = 0
        let paste = sensitivePaste(board, didWrite: { reported.append($0) })
        _ = await pasteSecret(paste, restoreInstead: { handed += 1 })
        await paste.pendingRestore?.value
        #expect(handed == 1)
        #expect(board.restores == [previous])
        #expect(board.items == previous)
        #expect(reported.count == 2)
        #expect(reported.last == board.changeCount)
    }
}
