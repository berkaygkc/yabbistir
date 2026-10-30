import AppKit
import SwiftUI

/// A borderless, non-activating child window of the panel for surfaces that reach outside it
/// (⌘P, the preview, the category editor). It moves and hides with the panel. The Sıra window
/// is one too, standing on its own.
@MainActor
final class FloatingSurface: NSPanel {
    private let keyable: Bool
    /// The owner alone sizes the window; a hosting view that sized it too grew it from the bottom.
    private let sizedByOwner: Bool
    private var host: SurfaceHostingView?
    /// Esc inside the surface (also from a focused text field).
    var onCancel: (() -> Void)?
    /// Keys the surface handles before its views (true: consumed), e.g. ↑/↓ and ⇥ in the editor.
    var onKeyDown: ((NSEvent) -> Bool)?
    /// ⌘ shortcuts the surface handles itself (true: consumed), e.g. ⌘N in the editor.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    init(canBecomeKey: Bool, sizedByOwner: Bool = false) {
        keyable = canBecomeKey
        self.sizedByOwner = sizedByOwner
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        sharingType = .none // hidden during screen sharing, like the panel
    }

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    /// App-level shortcuts would reach the main menu from here (⌘Q quits, ⌘, opens an empty
    /// Settings window); text editing (⌘C ⌘V ⌘X ⌘A ⌘Z) still reaches a focused field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, onKeyEquivalent?(event) == true { return true }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command), ["q", ",", "h", "m", "w"].contains(key) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// The content's natural size (width fixed by the content itself).
    func fittingSize<Content: View>(of content: Content) -> CGSize {
        setContent(content)
        return host?.fittingSize ?? .zero
    }

    func show<Content: View>(_ content: Content, frame: CGRect, above parent: NSWindow) {
        setContent(content)
        setFrame(frame, display: true)
        if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
        invalidateShadow()
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    private func setContent<Content: View>(_ content: Content) {
        if let host {
            host.rootView = AnyView(content)
        } else {
            let host = SurfaceHostingView(rootView: AnyView(content))
            if sizedByOwner { host.sizingOptions = [] }
            contentView = host
            self.host = host
        }
    }
}

/// Acts on the first click even when its window is not key: the Sıra window never becomes key,
/// so the frontmost app keeps the keyboard and its ⌘V.
private final class SurfaceHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
