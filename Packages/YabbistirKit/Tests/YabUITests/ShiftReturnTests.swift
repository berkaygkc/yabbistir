import Foundation
import Testing
import YabCore
import YabTestSupport
@testable import YabUI

@MainActor @Suite struct ShiftReturnTests {
    @Test func richTextKeepsPlainTextPaste() {
        #expect(ShiftReturn.resolve(isRich: true, transforms: ["x/b64"], pinned: nil) == .plainText)
    }

    @Test func plainItemsPasteAsTheyAre() {
        #expect(ShiftReturn.resolve(isRich: false, transforms: ["dev.yabbistir.base64/encode"], pinned: nil) == .paste)
    }

    @Test func aPinnedDefaultWins() {
        #expect(ShiftReturn.resolve(isRich: true, transforms: ["a", "b"], pinned: "b") == .command("b"))
    }

    @Test func aPinnedDefaultThatDoesNotApplyFallsBack() {
        #expect(ShiftReturn.resolve(isRich: false, transforms: ["a"], pinned: "gone") == .paste)
        #expect(ShiftReturn.resolve(isRich: true, transforms: [], pinned: "gone") == .plainText)
        #expect(ShiftReturn.resolve(isRich: false, transforms: [], pinned: ShiftReturn.plainTextID) == .paste)
    }

    @Test func codeSharesTheTextDefault() {
        #expect(ShiftKind(.code) == .text)
        #expect(ShiftKind(.link) == .link)
    }

    @Test func pinsPersistPerKindAndCanBeRemoved() throws {
        let suite = TestScratch.suiteName("yab-ui")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShiftReturnDefaults(defaults: defaults)
        store.pin("x/b64", for: .link)
        #expect(store.pinned(for: .link) == "x/b64")
        #expect(store.pinned(for: .text) == nil)
        #expect(ShiftReturnDefaults(defaults: defaults).pinned(for: .link) == "x/b64")
        store.pin(nil, for: .link)
        #expect(store.pinned(for: .link) == nil)
    }
}
