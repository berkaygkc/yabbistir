import AppKit
import SwiftUI
import YabPlatform

/// Brings the history panel on screen with its entrance animation.
@MainActor
public enum PanelPresentation {
    public static func show(_ window: NSWindow, frame: CGRect, model: PanelViewModel) {
        model.isPresented = false
        model.reset()
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
        // NSHostingView loses an animated change made in the turn its window comes on screen: the
        // panel stayed transparent until the next keystroke. Commit the hidden state first.
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        withAnimation(Tokens.Motion.resolved(Tokens.Motion.panelEnter)) { model.isPresented = true }
    }

    /// The hosting view for the panel's window. It must not size the window: the width comes from
    /// `model.sheetWidth` through `fitWidth`, so the window springs and stays on screen; left to
    /// itself the hosting view snapped the window to the strip's full content width.
    public static func host<Content: View>(_ view: Content) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        return host
    }

    /// Resizes the window to the model's sheet width in whole columns, keeping it on screen, with
    /// a spring (0.46 s); instant under Reduce Motion.
    public static func fitWidth(_ window: NSWindow, model: PanelViewModel, visibleFrame: CGRect,
                                completion: @escaping @MainActor () -> Void = {}) {
        let target = model.sheetWidth
        guard window.isVisible, abs(window.frame.width - target) > 0.5 else { return }
        let frame = PanelPlacement.resized(window.frame, toWidth: target, visibleFrame: visibleFrame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.reduceMotion() ? 0 : 0.46
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.32, 0.64, 1)
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                window.invalidateShadow()
                completion()
            }
        }
    }
}
