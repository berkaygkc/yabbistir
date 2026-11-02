import AppKit
import SwiftUI
import YabLocalization
import YabPlatform
import YabUI

/// The first-run window: shown once on a new install and again from Settings › About. Every showing is a new first-run
/// session. Finishing (or Esc, or the close button) fades the window out, gives the keyboard back to the app that had
/// it, then opens the panel there.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let importer: ImportModel
    private let preferences: Preferences
    private let language: LanguageStore
    private let loginItem: LoginItemControlling
    private let openPanel: () -> Void
    private var window: OnboardingWindow?
    private var model: OnboardingModel?
    /// The app in front before the window came up; it gets the keyboard back when the window goes.
    private var previousApp: NSRunningApplication?

    init(importer: ImportModel, preferences: Preferences, language: LanguageStore, loginItem: LoginItemControlling,
         openPanel: @escaping () -> Void) {
        self.importer = importer
        self.preferences = preferences
        self.language = language
        self.loginItem = loginItem
        self.openPanel = openPanel
    }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : front
        let model = OnboardingModel(
            importer: importer, preferences: preferences, language: language, loginItem: loginItem,
            isTrusted: AccessibilityPermission.isTrusted, promptAccessibility: AccessibilityPermission.prompt,
            onFinish: { [weak self] in self?.dismiss() })
        // Run again from About: the switch shows how the app opens now, so finishing never turns it back on unasked.
        if preferences.onboarded {
            model.launchAtLogin = [.enabled, .requiresApproval].contains(loginItem.status)
        }
        self.model = model

        let window = OnboardingWindow()
        let content = OnboardingView(model: model)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                self?.fit(height: height)
            }
        let host = NSHostingView(rootView: content.ignoresSafeArea())
        // Measured before it joins the window (inside it, the title bar's safe area is added on top). From then on the
        // window is sized here, around its middle; left to itself the hosting view grew it from the bottom.
        let size = host.fittingSize
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        window.center()
        window.delegate = self
        window.onEscape = { [weak model] in model?.escape() }
        window.onReturn = { [weak model] in model?.primary() }
        self.window = window
        present(window)
        // Looks for a library to bring along: once for each showing.
        Task { await model.appear() }
    }

    // MARK: Showing and going

    /// Fades in as it rises 10 pt (0.3 s and 0.45 s, an expo ease-out); with Reduce Motion it only fades.
    private func present(_ window: OnboardingWindow) {
        let target = window.frame
        let still = Tokens.Motion.reduceMotion()
        window.alphaValue = 0
        if !still { window.setFrame(target.offsetBy(dx: 0, dy: -10), display: false) }
        // A menu bar app: the window comes forward only when the app does.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.placeTrafficLights()
        window.followTitleBarLayout()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = Self.ease
            window.animator().alphaValue = 1
        }
        guard !still else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = Self.ease
            window.animator().setFrame(target, display: true)
        } completionHandler: {
            MainActor.assumeIsolated { window.invalidateShadow() }
        }
    }

    /// The model has finished: fade out (280 ms) as the window sinks back, hand the keyboard back, then open the panel
    /// for that app once it is in front again.
    private func dismiss() {
        guard let window else { return }
        let still = Tokens.Motion.reduceMotion()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = Self.ease
            window.animator().alphaValue = 0
            if !still { window.animator().setFrame(window.frame.offsetBy(dx: 0, dy: -10), display: true) }
        } completionHandler: {
            MainActor.assumeIsolated { self.closed() }
        }
    }

    private func closed() {
        window?.orderOut(nil)
        window?.delegate = nil
        window = nil
        model = nil
        if let app = previousApp, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            NSApp.deactivate()
        }
        previousApp = nil
        let openPanel = openPanel
        Task { @MainActor in
            // The panel opens for the app in front: give it a beat to get there.
            try? await Task.sleep(for: .milliseconds(250))
            openPanel()
        }
    }

    /// Keeps the window's middle where it is as a step makes it taller or shorter.
    private func fit(height: CGFloat) {
        guard let window, height > 0, abs(window.frame.height - height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y = frame.midY - height / 2
        frame.size.height = height
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }

    private static let ease = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    // MARK: NSWindowDelegate

    /// The close button and ⌘W finish like Esc does: the window fades out itself.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model?.escape()
        return false
    }

    func windowDidResize(_ notification: Notification) { window?.placeTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { window?.placeTrafficLights() }
    func windowDidResignKey(_ notification: Notification) { window?.placeTrafficLights() }
}

/// A titled window drawn entirely by its content: a clear, transparent title bar over the glass sheet, the system's
/// traffic lights moved into the sheet's 44 pt bar.
final class OnboardingWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?

    /// The center of the close button, from the window's top-left corner: concentric with the 24 pt corner.
    private static let lightsCenter = CGPoint(x: 22, y: 22)
    private static let barHeight: CGFloat = 44

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 474),
                   styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "yabbistir"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isRestorable = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
    }

    /// Esc finishes; Return presses the step's primary button while it is enabled. Both are taken before the views see
    /// them, so a focused control never swallows them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            switch event.keyCode {
            case 53:
                onEscape?()
                return
            case 36, 76:
                onReturn?()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    /// The title bar container grows to the 44 pt bar and the buttons are centered in it, the close button's center
    /// 22 pt from the left; their own spacing stays the system's. Run again whenever AppKit lays the title bar out.
    func placeTrafficLights() {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
        guard let close = buttons.first, let container = close.superview?.superview else { return }
        var bar = container.frame
        if bar.height != Self.barHeight || bar.maxY != frame.height {
            bar.size.height = Self.barHeight
            bar.origin.y = frame.height - Self.barHeight
            container.frame = bar
        }
        let shift = Self.lightsCenter.x - close.frame.midX
        for button in buttons {
            let origin = NSPoint(x: button.frame.minX + shift, y: (Self.barHeight - button.frame.height) / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    /// AppKit lays the title bar out again now and then (a change of key window, of appearance); the buttons go back
    /// into the bar each time.
    func followTitleBarLayout() {
        guard observer == nil, let container = standardWindowButton(.closeButton)?.superview?.superview else { return }
        container.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: container,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeTrafficLights() }
        }
    }

    private var observer: NSObjectProtocol?

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
