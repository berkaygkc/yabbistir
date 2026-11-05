import Observation

/// The Settings section on screen, and the Extensions tab. Kept outside the views, so a link can point the window at
/// the Store before it comes forward.
@MainActor @Observable
public final class SettingsNavigation {
    public var section: SettingsSection? = .general
    public var extensionsTab: ExtensionsSettingsView.Tab = .installed

    public init() {}

    /// Settings › Extensions › Store.
    public func showStore() {
        section = .extensions
        extensionsTab = .store
    }

    /// Follows a `yabbistir://` link. `showWindow` brings the Settings window forward (a closed window starts a new
    /// Settings session); `bringForward` only activates the app. An install link hands its ids to `store` after the
    /// window is up, so they wait for the catalog that session checks.
    public func open(_ link: AppLink, store: StoreModel, showWindow: () -> Void, bringForward: () -> Void) {
        switch link {
        case .store:
            showStore()
            showWindow()
        case .install(let ids):
            showStore()
            showWindow()
            store.offer(ids)
        case .other:
            bringForward()
        }
    }
}
