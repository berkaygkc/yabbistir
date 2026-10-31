import AppKit
import SwiftUI
import YabLocalization
import YabUI

/// The Settings window (⌘, from the menu bar menu): one window, made on first use and kept.
@MainActor
final class SettingsWindowController {
    private let model: ExtensionsSettingsModel
    private let store: StoreModel
    private var window: NSWindow?

    init(model: ExtensionsSettingsModel, store: StoreModel) {
        self.model = model
        self.store = store
    }

    func show() {
        // Opening the window starts a new Settings session: the Store checks the catalog again the first time it is
        // shown (straight away, if it is the tab on screen).
        if window?.isVisible != true { store.beginSession() }
        let window = window ?? makeWindow()
        self.window = window
        window.title = L10n.string("settings.title", model.language)
        // A menu bar app: the window comes forward only when the app does.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model, store: store))
        window.toolbar = NSToolbar(identifier: "settings")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 580))
        window.center()
        window.setFrameAutosaveName("Settings")
        return window
    }
}
