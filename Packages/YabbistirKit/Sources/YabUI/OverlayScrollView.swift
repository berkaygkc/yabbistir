import AppKit
import SwiftUI

/// Forces the enclosing NSScrollView to overlay ("ghost") scrollers, so a scroll bar
/// never takes layout space, even with "Show scroll bars: Always" or a mouse attached.
/// Place it as a background inside a SwiftUI ScrollView's content.
struct OverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerStyleProbe { ScrollerStyleProbe() }
    func updateNSView(_ nsView: ScrollerStyleProbe, context: Context) { nsView.apply() }
}

final class ScrollerStyleProbe: NSView {
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        guard observer == nil else { return }
        // The system resets scroller style when the user's preference or input devices change.
        observer = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    func apply() {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
