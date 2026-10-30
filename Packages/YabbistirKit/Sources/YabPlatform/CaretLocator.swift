import AppKit
import ApplicationServices

/// Finds where the user is typing, via Accessibility. Many apps expose the caret
/// (Cocoa text views, Safari, Notes); Electron and Chromium apps do not
/// unless their accessibility mode is on, which yabbistir leaves to the user.
@MainActor
public enum CaretLocator {
    /// The caret rectangle in Cocoa global coordinates, or nil if the focused app does not expose it.
    public static func caretRect() -> CGRect? {
        caretRect(using: SystemAX(), primaryScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    /// Short enough that a hung or busy app (a beachballing IDE) costs a blink, not AX's default ~6 s.
    static let messagingTimeout: Float = 0.1

    static func caretRect(using ax: AXQuerying, primaryScreenMaxY: CGFloat) -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()
        // Set on the system-wide element, the timeout applies to every AX call this process makes.
        ax.setMessagingTimeout(systemWide, seconds: messagingTimeout)
        guard let element = uiElement(ax.value(of: kAXFocusedUIElementAttribute, on: systemWide)),
              let rangeValue = axValue(ax.value(of: kAXSelectedTextRangeAttribute, on: element)) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), let rect = caretBounds(ax, range, element) else { return nil }
        // A range scrolled out of view (Terminal's scrollback) reports a rectangle the user cannot see.
        if let frame = frame(ax, element), !frame.insetBy(dx: -4, dy: -4).contains(CGPoint(x: rect.minX, y: rect.midY)) {
            return nil
        }
        // AX rectangles use a top-left origin on the primary screen; Cocoa uses bottom-left.
        return CGRect(x: rect.minX, y: primaryScreenMaxY - rect.maxY, width: max(rect.width, 1), height: rect.height)
    }

    /// Some apps (Terminal) answer the empty range at the caret with an empty rectangle;
    /// then the caret sits after the previous character, or before the first one.
    private static func caretBounds(_ ax: AXQuerying, _ range: CFRange, _ element: AXUIElement) -> CGRect? {
        if let rect = bounds(ax, range, element) { return rect }
        guard range.length == 0 else { return nil }
        if range.location > 0, let previous = bounds(ax, CFRange(location: range.location - 1, length: 1), element) {
            return CGRect(x: previous.maxX, y: previous.minY, width: 1, height: previous.height)
        }
        if let next = bounds(ax, CFRange(location: range.location, length: 1), element) {
            return CGRect(x: next.minX, y: next.minY, width: 1, height: next.height)
        }
        return nil
    }

    private static func bounds(_ ax: AXQuerying, _ range: CFRange, _ element: AXUIElement) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range),
              let value = axValue(ax.value(of: kAXBoundsForRangeParameterizedAttribute, on: element, parameter: parameter)) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect), rect.height > 0, rect != .zero else { return nil }
        return rect
    }

    private static func frame(_ ax: AXQuerying, _ element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let position = axValue(ax.value(of: kAXPositionAttribute, on: element)), AXValueGetValue(position, .cgPoint, &origin),
              let extent = axValue(ax.value(of: kAXSizeAttribute, on: element)), AXValueGetValue(extent, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func uiElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    /// Fallback anchor: a caret-sized rectangle under the mouse pointer.
    public static func mouseAnchor() -> CGRect {
        let point = NSEvent.mouseLocation
        return CGRect(x: point.x, y: point.y - 18, width: 1, height: 18)
    }

    /// The visible frame of the screen containing `rect`, falling back to the main screen.
    public static func visibleFrame(containing rect: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? NSScreen.main
        return screen?.visibleFrame ?? .zero
    }
}

/// The Accessibility calls the caret lookup makes, so tests can stand in for the focused app.
protocol AXQuerying {
    func setMessagingTimeout(_ element: AXUIElement, seconds: Float)
    func value(of attribute: String, on element: AXUIElement) -> CFTypeRef?
    func value(of attribute: String, on element: AXUIElement, parameter: CFTypeRef) -> CFTypeRef?
}

struct SystemAX: AXQuerying {
    func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    func value(of attribute: String, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func value(of attribute: String, on element: AXUIElement, parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success else { return nil }
        return value
    }
}
