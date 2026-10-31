import AppKit
import Testing
@testable import YabUI

@Suite struct PanelKeyRouterTests {
    func route(_ keyCode: UInt16, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = []) -> PanelCommand? {
        PanelKeyRouter.command(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    @Test func returnConfirms() { #expect(route(36, "\r") == .confirm(plain: false)) }
    @Test func shiftReturnConfirmsPlain() { #expect(route(36, "\r", .shift) == .confirm(plain: true)) }
    @Test func arrowsMove() {
        #expect(route(125) == .move(1))
        #expect(route(126) == .move(-1))
    }
    @Test func escapeEscapes() { #expect(route(53, "\u{1b}") == .escape) }
    @Test func deleteDeletesBackward() { #expect(route(51, "\u{7f}") == .deleteBackward) }
    @Test func letterTypes() { #expect(route(0, "a") == .type("a")) }
    @Test func turkishLetterTypes() { #expect(route(41, "ş") == .type("ş")) }
    @Test func commandShortcutsAreNotTyped() { #expect(route(9, "v", .command) == .swallow) }
    @Test func commandASelectsAll() { #expect(route(0, "a", .command) == .selectAll) }
    @Test func commandASelectsAllOnTurkishF() { #expect(route(4, "a", .command) == .selectAll) }

    @Test func optionArrowsMoveItems() {
        #expect(route(126, nil, .option) == .moveItem(-1))
        #expect(route(125, nil, .option) == .moveItem(1))
    }
    @Test func arrowsMoveColumns() {
        #expect(route(123) == .moveColumn(-1))
        #expect(route(124) == .moveColumn(1))
    }
    @Test func commandDigitsPaste() { #expect(route(19, "2", .command) == .pasteIndex(2)) }
    @Test func commandShortcuts() {
        #expect(route(8, "c", .command) == .copy)
        #expect(route(51, "\u{7f}", .command) == .delete)
        #expect(route(40, "k", .command) == .toggleActions)
        #expect(route(35, "p", .command) == .togglePin)
        #expect(route(14, "e", .command) == .openEditor)
    }
    @Test func unknownCommandShortcutsAreSwallowed() {
        #expect(route(12, "q", .command) == .swallow)
        #expect(route(43, ",", .command) == .swallow)
    }
    @Test func tabOpensTheCategoryMenu() { #expect(route(48, "\t") == .toggleCategoryMenu) }
    @Test func commandAloneIsHeld() {
        #expect(PanelKeyRouter.commandHeld(.command))
        #expect(!PanelKeyRouter.commandHeld([.command, .shift]))
    }
    @Test func shiftAloneIsHeld() {
        #expect(PanelKeyRouter.shiftHeld(.shift))
        #expect(PanelKeyRouter.shiftHeld([.shift, .capsLock]))
        #expect(!PanelKeyRouter.shiftHeld([.shift, .command]))
        #expect(!PanelKeyRouter.shiftHeld([]))
    }
}
