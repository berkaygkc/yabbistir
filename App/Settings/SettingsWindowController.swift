import AppKit
import SwiftUI
import YabLocalization
import YabUI

/// The Settings window (⌘, from the menu bar menu): one window, made on first use and kept.
@MainActor
final class SettingsWindowController {
    private let model: ExtensionsSettingsModel
    private var window: NSWindow?

    init(model: ExtensionsSettingsModel) {
        self.model = model
    }

    func show() {
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
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
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
