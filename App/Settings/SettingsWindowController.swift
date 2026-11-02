import AppKit
import Observation
import SwiftUI
import YabLocalization
import YabUI

/// The Settings window (⌘, from the menu bar menu): one window, made on first use and kept.
@MainActor
final class SettingsWindowController {
    private let models: SettingsModels
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(models: SettingsModels) {
        self.models = models
    }

    func show() {
        // Opening the window starts a new Settings session: the Store checks the catalog again the first time it is
        // shown (straight away, if it is the tab on screen).
        if window?.isVisible != true { models.store.beginSession() }
        if window == nil {
            window = makeWindow()
            followLanguage()
        }
        guard let window else { return }
        models.presence.shown()
        // A menu bar app: the window comes forward only when the app does.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: SettingsView(models: models))
        window.toolbar = NSToolbar(identifier: "settings")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 460)
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 580))
        window.center()
        window.setFrameAutosaveName("Settings")
        observe(window)
        return window
    }

    /// Tells the pages when the window closes and when it comes forward, so they stop polling and read the system again.
    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        let presence = models.presence
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { presence.closed() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { presence.cameForward() }
            },
        ]
    }

    /// The title follows the app's language while the window is open.
    private func followLanguage() {
        let language = withObservationTracking {
            models.language.language
        } onChange: { [weak self] in
            Task { @MainActor in self?.followLanguage() }
        }
        window?.title = L10n.string("settings.title", language)
    }
}
