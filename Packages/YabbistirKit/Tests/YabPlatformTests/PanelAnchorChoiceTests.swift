import CoreGraphics
import Testing
@testable import YabPlatform

@Suite struct PanelAnchorChoiceTests {
    let caret = CGRect(x: 10, y: 20, width: 2, height: 17)
    let pointer = CGRect(x: 300, y: 400, width: 1, height: 1)
    let explicit = CGRect(x: 900, y: 10, width: 24, height: 24)

    @Test func explicitWins() {
        for position in PanelPosition.allCases {
            #expect(PanelAnchorChoice.anchor(position: position, explicit: explicit, caret: { caret }, pointer: { pointer }) == explicit)
        }
    }

    @Test func pointerSkipsTheCaret() {
        var asked = false
        let anchor = PanelAnchorChoice.anchor(position: .pointer, explicit: nil, caret: { asked = true; return caret }, pointer: { pointer })
        #expect(anchor == pointer)
        #expect(!asked)
    }

    @Test func caretFallsBackToThePointer() {
        #expect(PanelAnchorChoice.anchor(position: .caret, explicit: nil, caret: { nil }, pointer: { pointer }) == pointer)
        #expect(PanelAnchorChoice.anchor(position: .caret, explicit: nil, caret: { caret }, pointer: { pointer }) == caret)
    }
}
