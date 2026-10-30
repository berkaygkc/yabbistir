import ApplicationServices
import Testing
@testable import YabPlatform

/// Stands in for the focused app's Accessibility answers. Rectangles use AX's top-left origin.
final class FakeAX: AXQuerying {
    var timeout: Float?
    var askedBeforeTimeout = false
    var selection = CFRange(location: 5, length: 0)
    var elementFrame: CGRect? = CGRect(x: 0, y: 0, width: 800, height: 600)
    var bounds: [[Int]: CGRect] = [:]
    private let focused = AXUIElementCreateApplication(1)

    func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        timeout = seconds
    }

    func value(of attribute: String, on element: AXUIElement) -> CFTypeRef? {
        if timeout == nil { askedBeforeTimeout = true }
        switch attribute {
        case kAXFocusedUIElementAttribute:
            return focused
        case kAXSelectedTextRangeAttribute:
            var range = selection
            return AXValueCreate(.cfRange, &range)
        case kAXPositionAttribute:
            guard var origin = elementFrame?.origin else { return nil }
            return AXValueCreate(.cgPoint, &origin)
        case kAXSizeAttribute:
            guard var size = elementFrame?.size else { return nil }
            return AXValueCreate(.cgSize, &size)
        default:
            return nil
        }
    }

    func value(of attribute: String, on element: AXUIElement, parameter: CFTypeRef) -> CFTypeRef? {
        var range = CFRange()
        guard attribute == kAXBoundsForRangeParameterizedAttribute,
              AXValueGetValue(parameter as! AXValue, .cfRange, &range),
              var rect = bounds[[range.location, range.length]] else { return nil }
        return AXValueCreate(.cgRect, &rect)
    }
}

@MainActor @Suite struct CaretLocatorTests {
    let ax = FakeAX()

    func caret() -> CGRect? {
        CaretLocator.caretRect(using: ax, primaryScreenMaxY: 1000)
    }

    @Test func limitsTheMessagingTimeoutBeforeAskingTheApp() {
        ax.bounds[[5, 0]] = CGRect(x: 100, y: 200, width: 1, height: 16)
        _ = caret()
        #expect(ax.timeout.map { $0 <= 0.1 } == true)
        #expect(!ax.askedBeforeTimeout)
    }

    @Test func convertsToCocoaCoordinates() {
        ax.bounds[[5, 0]] = CGRect(x: 100, y: 200, width: 1, height: 16)
        #expect(caret() == CGRect(x: 100, y: 784, width: 1, height: 16))
    }

    @Test func emptyCaretFallsBackToThePreviousCharacter() {
        // Terminal answers the empty range at the caret with an empty rectangle.
        ax.bounds[[5, 0]] = .zero
        ax.bounds[[4, 1]] = CGRect(x: 90, y: 200, width: 8, height: 16)
        #expect(caret() == CGRect(x: 98, y: 784, width: 1, height: 16))
    }

    @Test func emptyCaretAtTheStartUsesTheNextCharacter() {
        ax.selection = CFRange(location: 0, length: 0)
        ax.bounds[[0, 1]] = CGRect(x: 50, y: 200, width: 8, height: 16)
        #expect(caret() == CGRect(x: 50, y: 784, width: 1, height: 16))
    }

    @Test func caretOutsideTheFocusedElementIsIgnored() {
        // A range scrolled out of view reports a rectangle the user cannot see.
        ax.bounds[[5, 0]] = CGRect(x: 100, y: 900, width: 1, height: 16)
        #expect(caret() == nil)
    }
}
