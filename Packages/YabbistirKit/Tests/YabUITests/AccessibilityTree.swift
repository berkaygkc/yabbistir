import AppKit
import SwiftUI

/// A SwiftUI view's accessibility elements as VoiceOver reads them. SwiftUI builds them only while an assistive app is
/// on; `accessibilityEnabled` in the environment stands in for one.
@MainActor enum AccessibilityTree {
    /// `view` hosted in an offscreen window `size` big, with its elements built. Keep the window while you use the host.
    static func host(_ view: some View, size: NSSize) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: view.environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        settle(host)
        return (window, host)
    }

    /// Lets SwiftUI catch up with a change.
    static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
    }

    /// Every element under `root` (itself included), depth first.
    static func elements(under root: Any) -> [Element] {
        let object = root as AnyObject
        return [Element(object: object)] + ((object.accessibilityChildren?() ?? nil) ?? []).flatMap(elements(under:))
    }

    /// One element, read through the NSAccessibility protocol SwiftUI's nodes answer.
    struct Element {
        let object: AnyObject

        var role: String? { object.accessibilityRole?()?.rawValue }
        var label: String? { object.accessibilityLabel?() ?? nil }
        var help: String? { object.accessibilityHelp?() ?? nil }
        var value: String? {
            guard let node = object as? NSObject, node.responds(to: Selector(("accessibilityValue"))) else { return nil }
            return node.value(forKey: "accessibilityValue") as? String
        }
        /// In screen coordinates.
        var frame: NSRect? { object.accessibilityFrame?() }

        /// What VoiceOver's "show menu" does (VO-Shift-M); a menu button opens its menu.
        func showMenu() -> Bool { object.accessibilityPerformShowMenu?() ?? false }
    }
}
