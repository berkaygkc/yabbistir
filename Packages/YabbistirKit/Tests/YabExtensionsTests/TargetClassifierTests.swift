import Testing
import YabExtensionKit
import YabPasteboard

@Suite struct TargetClassifierTests {
    @Test func terminalsMatchThePasteRules() {
        #expect(TargetClassifier.terminals == PasteRules.terminalBundleIDs)
    }
}
