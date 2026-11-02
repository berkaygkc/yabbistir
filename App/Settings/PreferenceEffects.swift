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
        followCapture()
        followExtensionOutputs()
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

    /// yabbistir's own surfaces: the panel, the floating surfaces and the notices. The Settings window and the status item
    /// stay as macOS shows them.
    private func followScreenSharing() {
        let hidden = withObservationTracking {
            preferences.hidesFromScreenSharing
        } onChange: { [weak self] in
            Task { @MainActor in self?.followScreenSharing() }
        }
        let type = Self.sharingType(hidden: hidden)
        for window in NSApp.windows where Self.isOwnSurface(window) {
            window.sharingType = type
        }
        NoticeHUD.setSharingType(type)
    }

    private static func isOwnSurface(_ window: NSWindow) -> Bool {
        window is PanelWindow || window is FloatingSurface
    }

    /// What is captured: the ignored apps and iPhone copies, which apply from the next copy.
    private func followCapture() {
        let (apps, remote) = withObservationTracking {
            (preferences.ignoredApps, preferences.keepsRemoteCopies)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followCapture() }
        }
        env.monitor.filter.ignoredBundleIDs = Set(apps)
        env.monitor.filter.captureRemote = remote
    }

    /// Whether History lists the extensions' results; open views redraw.
    private func followExtensionOutputs() {
        let shown = withObservationTracking {
            preferences.showsExtensionOutputs
        } onChange: { [weak self] in
            Task { @MainActor in self?.followExtensionOutputs() }
        }
        env.library.setHidesExtensionOutputs(!shown)
    }
}
