import AppKit
import Testing
@testable import YabUI

@Suite struct PanelKeyRouterTests {
    func route(_ keyCode: UInt16, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = []) -> PanelCommand? {
        PanelKeyRouter.command(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    func route(_ keyCode: UInt16, _ characters: String?, _ modifiers: NSEvent.ModifierFlags, composing: Bool, inputMethod: Bool) -> PanelKeyRoute {
        PanelKeyRouter.route(keyCode: keyCode, characters: characters, modifiers: modifiers, composing: composing, inputMethod: inputMethod)
    }

    func command(_ keyCode: UInt16, _ characters: String?, _ modifiers: NSEvent.ModifierFlags = []) -> PanelCommand? {
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

    // MARK: Input methods

    @Test func lettersGoToTheInputMethod() {
        #expect(route(0, "n", [], composing: false, inputMethod: true) == .inputMethod)
    }
    @Test func spaceOpensThePreviewWhenNothingIsComposed() {
        #expect(route(49, " ", [], composing: false, inputMethod: true) == .command(.togglePreview))
    }
    @Test func composingKeysBelongToTheInputMethod() {
        #expect(route(49, " ", [], composing: true, inputMethod: true) == .inputMethod)
        #expect(route(36, "\r", [], composing: true, inputMethod: true) == .inputMethod)
        #expect(route(53, "\u{1b}", [], composing: true, inputMethod: true) == .inputMethod)
        #expect(route(125, nil, [], composing: true, inputMethod: true) == .inputMethod)
        #expect(route(51, "\u{7f}", [], composing: true, inputMethod: true) == .inputMethod)
    }
    @Test func plainLayoutsTypeAsToday() {
        #expect(route(0, "a", [], composing: false, inputMethod: false) == .command(.type("a")))
    }
    @Test func returnPastesWhenNothingIsComposed() {
        #expect(route(36, "\r", [], composing: false, inputMethod: true) == .command(.confirm(plain: false)))
    }
    @Test func commandShortcutsWorkWhileComposing() {
        #expect(route(40, "k", .command, composing: true, inputMethod: true) == .command(.toggleActions))
    }
    @Test func keysWithoutACommandGoToTheSystem() {
        #expect(route(0, "\u{1}", .control, composing: false, inputMethod: false) == .system)
    }
    @Test func commandTTogglesTransforms() { #expect(command(17, "t", .command) == .toggleTransforms) }
    @Test func commandShortcutsFollowTheKeyUnderHangulAndKana() {
        #expect(command(40, "ㅏ", .command) == .toggleActions)
        #expect(command(8, "ㅊ", .command) == .copy)
        #expect(command(18, "ぬ", .command) == .pasteIndex(1))
        #expect(command(17, "か", .command) == .toggleTransforms)
        #expect(command(12, "ㅂ", .command) == .swallow)
    }
    /// A Latin layout's own letters and symbols under ⌘ (Turkish F, AZERTY, Czech) are never read as another key.
    @Test func latinCommandKeysKeepTheirLayout() {
        #expect(command(14, "ğ", .command) == .swallow)
        #expect(command(19, "é", .command) == .swallow)
        #expect(command(22, "§", .command) == .swallow)
        #expect(command(20, "š", .command) == .swallow)
        #expect(command(14, "ế", .command) == .swallow)
    }
    @Test func shiftTapOpensTransformsOnPlainLayoutsOnly() {
        #expect(PanelKeyRouter.shiftTapCommand(inputMethod: false) == .toggleTransforms)
        #expect(PanelKeyRouter.shiftTapCommand(inputMethod: true) == nil)
    }

    @Test func shiftAloneIsHeld() {
        #expect(PanelKeyRouter.shiftHeld(.shift))
        #expect(PanelKeyRouter.shiftHeld([.shift, .capsLock]))
        #expect(!PanelKeyRouter.shiftHeld([.shift, .command]))
        #expect(!PanelKeyRouter.shiftHeld([]))
    }
}
