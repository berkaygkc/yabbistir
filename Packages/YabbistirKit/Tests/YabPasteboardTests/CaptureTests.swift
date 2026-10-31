import Foundation
import Testing
import YabCore
@testable import YabPasteboard

func rep(_ type: String, _ s: String) -> PasteboardRepresentation {
    PasteboardRepresentation(type: type, data: Data(s.utf8))
}

final class FakePasteboard: PasteboardReading {
    var changeCount = 0
    var items: [[PasteboardRepresentation]] = []

    func readItems() -> [[PasteboardRepresentation]] { items }

    func copy(_ s: String, extraTypes: [String] = []) {
        changeCount += 1
        items = [[rep(TypeIdentifiers.plainText, s)] + extraTypes.map { rep($0, "") }]
    }
}

final class FakeApps: FrontmostAppProviding {
    var app: SourceApp? = SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit")
    func frontmostApplication() -> SourceApp? { app }
}

@Suite struct CaptureFilterTests {
    let filter = CaptureFilter()
    let textEdit = SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit")

    @Test func concealedTypeSkips() {
        #expect(filter.evaluate(types: [TypeIdentifiers.plainText, "org.nspasteboard.ConcealedType"], source: textEdit) == .skip(.concealed))
    }

    @Test func ignoredAppSkips() {
        let passwords = SourceApp(bundleID: "com.apple.Passwords", name: "Passwords")
        #expect(filter.evaluate(types: [TypeIdentifiers.plainText], source: passwords) == .skip(.ignoredApp("com.apple.Passwords")))
    }

    @Test func passwordsMenuBarItemSkips() {
        let menuBar = SourceApp(bundleID: "com.apple.Passwords.MenuBarExtra", name: "Passwords")
        #expect(filter.evaluate(types: [TypeIdentifiers.plainText], source: menuBar) == .skip(.ignoredApp("com.apple.Passwords.MenuBarExtra")))
    }

    @Test func remoteTypeCapturesAsRemote() {
        #expect(filter.evaluate(types: [TypeIdentifiers.plainText, CaptureFilter.remoteClipboardType], source: textEdit) == .capture(.remote))
    }

    @Test func remoteDisabledSkips() {
        var f = filter
        f.captureRemote = false
        #expect(f.evaluate(types: [CaptureFilter.remoteClipboardType], source: textEdit) == .skip(.remoteDisabled))
    }

    @Test func normalCaptureIsLocal() {
        #expect(filter.evaluate(types: [TypeIdentifiers.plainText], source: textEdit) == .capture(.local))
    }
}

@MainActor @Suite struct PasteboardMonitorTests {
    let board = FakePasteboard()
    let apps = FakeApps()
    let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

    func monitor(_ sink: @escaping (CapturedClip) -> Void) -> PasteboardMonitor {
        PasteboardMonitor(reader: board, apps: apps, filter: CaptureFilter(), now: { self.now }, onCapture: { clip, _ in sink(clip) })
    }

    /// The change count read with the copy goes with it: a clean write later lands only over that same copy.
    @Test func captureCarriesItsChangeCount() {
        var counts: [Int] = []
        let m = PasteboardMonitor(reader: board, apps: apps, filter: CaptureFilter(), now: { self.now }) { _, count in counts.append(count) }
        board.copy("bir")
        board.copy("iki")
        m.poll()
        board.copy("üç")
        m.poll()
        #expect(counts == [2, 3])
    }

    @Test func noChangeNoCapture() {
        var captured: [CapturedClip] = []
        let m = monitor { captured.append($0) }
        m.poll()
        #expect(captured.isEmpty)
    }

    @Test func changeCapturesOnceWithSource() {
        var captured: [CapturedClip] = []
        let m = monitor { captured.append($0) }
        board.copy("merhaba")
        m.poll()
        m.poll()
        #expect(captured.count == 1)
        #expect(captured.first?.source?.bundleID == "com.apple.TextEdit")
        #expect(captured.first?.device == .local)
        #expect(captured.first?.capturedAt == now)
    }

    @Test func doubleChangeBetweenPollsCapturesLatestOnce() {
        var captured: [CapturedClip] = []
        let m = monitor { captured.append($0) }
        board.copy("birinci")
        board.copy("ikinci")
        m.poll()
        #expect(captured.count == 1)
        #expect(captured.first?.items == [[rep(TypeIdentifiers.plainText, "ikinci")]])
    }

    @Test func ignoredChangeCountIsNotCaptured() {
        var captured: [CapturedClip] = []
        let m = monitor { captured.append($0) }
        board.copy("yabbistir yazdı")
        m.ignore(changeCount: board.changeCount)
        m.poll()
        #expect(captured.isEmpty)
        board.copy("kullanıcı kopyaladı")
        m.poll()
        #expect(captured.count == 1)
    }

    @Test func concealedIsNotCaptured() {
        var captured: [CapturedClip] = []
        let m = monitor { captured.append($0) }
        board.copy("s3cr3t", extraTypes: ["org.nspasteboard.ConcealedType"])
        m.poll()
        #expect(captured.isEmpty)
    }

    @Test func copyInIgnoredAppIsSkippedAfterSwitchingAway() {
        var captured: [CapturedClip] = []
        apps.app = SourceApp(bundleID: "com.apple.Passwords", name: "Passwords")
        let m = monitor { captured.append($0) }
        m.poll()
        board.copy("hunter2")
        apps.app = SourceApp(bundleID: "com.apple.Safari", name: "Safari")
        m.poll()
        #expect(captured.isEmpty)
    }

    @Test func sourceIsTheAppInFrontBeforeTheSwitch() {
        var captured: [CapturedClip] = []
        apps.app = SourceApp(bundleID: "com.apple.Safari", name: "Safari")
        let m = monitor { captured.append($0) }
        m.poll()
        board.copy("bağlantı")
        apps.app = SourceApp(bundleID: "com.apple.Notes", name: "Notes")
        m.poll()
        #expect(captured.first?.source?.bundleID == "com.apple.Safari")
    }

    @Test func remoteClipHasNoLocalSource() {
        var captured: [CapturedClip] = []
        let m = monitor { captured.append($0) }
        board.copy("iPhone'dan", extraTypes: [CaptureFilter.remoteClipboardType])
        m.poll()
        #expect(captured.first?.device == .remote)
        #expect(captured.first?.source == nil)
    }
}
