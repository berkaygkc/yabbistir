import AppKit
import Observation
import YabUI

/// Applies the preferences that reach beyond Settings: the appearance, the menu bar icon and what screen sharing sees.
/// `start()` applies all of them once, then follows every change.
@MainActor
final class PreferenceEffects {
    private let preferences: Preferences
    private let env: AppEnvironment
    private let statusItem: StatusItemController

    init(preferences: Preferences, env: AppEnvironment, statusItem: StatusItemController) {
        self.preferences = preferences
        self.env = env
        self.statusItem = statusItem
    }

    /// Hidden windows are not captured at all; shown ones stay readable.
    static func sharingType(hidden: Bool) -> NSWindow.SharingType {
        hidden ? .none : .readOnly
    }

    func start() {
        followAppearance()
        followMenuBarIcon()
        followScreenSharing()
    }

    private func followAppearance() {
        let choice = withObservationTracking {
            preferences.appearance
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAppearance() }
        }
        NSApp.appearance = switch choice {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func followMenuBarIcon() {
        let shown = withObservationTracking {
            preferences.showsMenuBarIcon
        } onChange: { [weak self] in
            Task { @MainActor in self?.followMenuBarIcon() }
        }
        statusItem.isVisible = shown
    }

    /// Every window but Settings, which stays visible when the screen is shared.
    private func followScreenSharing() {
        let hidden = withObservationTracking {
            preferences.hidesFromScreenSharing
        } onChange: { [weak self] in
            Task { @MainActor in self?.followScreenSharing() }
        }
        let type = Self.sharingType(hidden: hidden)
        for window in NSApp.windows where window.identifier != NSUserInterfaceItemIdentifier("settings") {
            window.sharingType = type
        }
    }
}
