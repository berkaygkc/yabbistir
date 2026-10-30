import Testing
@testable import YabExtensionKit

@Suite struct TargetTests {
    @Test func finderTerminalsBrowsersAndEditorsAreKnown() {
        #expect(TargetClassifier.classify(bundleID: "com.apple.finder") == .finder)
        #expect(TargetClassifier.classify(bundleID: "com.apple.Terminal") == .terminal)
        #expect(TargetClassifier.classify(bundleID: "com.apple.Safari") == .browser)
        #expect(TargetClassifier.classify(bundleID: "com.microsoft.VSCode") == .editor)
        #expect(TargetClassifier.classify(bundleID: "com.jetbrains.intellij") == .editor)
        #expect(TargetClassifier.classify(bundleID: "com.example.unknown") == .other)
        #expect(TargetClassifier.classify(bundleID: nil) == .other)
    }
}
