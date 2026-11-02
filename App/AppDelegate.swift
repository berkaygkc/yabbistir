import AppKit
import YabExtensions
import YabPlatform
import YabUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment?
    private var panel: PanelController?
    private var stack: StackController?
    private var statusItem: StatusItemController?
    private var jobsCard: JobsSurfaceController?
    private var settings: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    private var effects: PreferenceEffects?
    #if DEBUG
    private let materialComparison = MaterialSpikeWindow()
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Before the store opens or the clipboard is watched: the other build may be using both.
        SingleInstance.replaceCounterpart()
        SingleInstance.yieldToLaterLaunches()
        do {
            let env = try AppEnvironment()
            // Read before anything is captured: a new install has nothing yet.
            let historyWasEmpty = env.library.index.count == 0
            env.start()
            // Built-ins and the person's extensions are read at launch; detectors new to the
            // history (a new extension or version) then tag it in the background. Reading them is a
            // registry change, which loads the extensions with capture rules right away
            // (`ExtensionService.preloadCaptureRules`), so the first copy finds them in.
            env.extensionRegistry.reload()
            Task { await env.extensions.backfill() }
            let stack = StackController(env: env)
            let panel = PanelController(env: env, stack: stack)
            let isPanelVisible = { [weak panel] in panel?.isVisible ?? false }
            // Jobs run in the jobs' own helper; a result meets the app in front, the panel and the Sıra.
            env.jobs = JobCenter(runner: env.extensions,
                                 environment: AppJobEnvironment(env: env, stack: stack.session, isPanelVisible: isPanelVisible))
            // Every registry change (a switch, a removal, the master switch, new permissions, too many
            // errors) stops the jobs of extensions that can no longer run.
            env.extensions.jobs = env.jobs
            let jobsCard = JobsSurfaceController(
                center: env.jobs, language: env.language,
                sharingType: PreferenceEffects.sharingType(hidden: env.preferences.hidesFromScreenSharing))
            self.jobsCard = jobsCard
            self.env = env
            self.panel = panel
            self.stack = stack
            let settingsModel = ExtensionsSettingsModel(
                registry: env.extensionRegistry, settings: env.extensionSettings, language: env.language, logs: env.extensionLogs)
            // The settings window's own copies (an install command) are not clipboard history.
            settingsModel.onPasteboardWrite = { [weak env] changeCount in env?.monitor.ignore(changeCount: changeCount) }
            let storeModel = StoreModel(
                client: env.storeClient, registry: env.extensionRegistry, language: env.language, logs: env.extensionLogs)
            let historyModel = HistorySettingsModel(
                preferences: env.preferences, library: env.library, storageDirectory: env.storageDirectory)
            historyModel.onCleared = { [weak env, weak stack] deleted in
                for id in deleted { stack?.session.itemDeleted(id) }
                env?.cleanResultFiles()
            }
            historyModel.onRetentionApplied = { [weak env] in env?.cleanResultFiles() }
            let loginItem = SystemLoginItem()
            // One import for Settings and the first-run window, so both show the same progress.
            let importer = ImportModel(store: env.library.store, reload: { [weak env] in try? env?.library.reloadIndex() },
                                       ignoredApps: { [weak env] in Set(env?.preferences.ignoredApps ?? []) },
                                       language: env.language)
            let onboarding = OnboardingWindowController(
                importer: importer, preferences: env.preferences, language: env.language, loginItem: loginItem,
                openPanel: { [weak panel] in panel?.show() })
            self.onboarding = onboarding
            let settings = SettingsWindowController(
                models: SettingsModels(
                    preferences: env.preferences, language: env.language,
                    general: GeneralSettingsModel(preferences: env.preferences, language: env.language, loginItem: loginItem),
                    history: historyModel,
                    categories: CategoryEditorModel(library: env.library, language: env.language, sources: env.sources),
                    extensions: settingsModel, store: storeModel,
                    permissions: PermissionsModel(probe: SystemPermissionProbe(loginItem: loginItem),
                                                  loginItem: loginItem, language: env.language),
                    importer: importer,
                    about: AboutModel(
                        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                        language: env.language,
                        checkForUpdates: { [weak env] in Task { await env?.checkForUpdates() } },
                        readNotice: Self.bundledText,
                        rerunSetup: { [weak onboarding] in onboarding?.show() }),
                    presence: SettingsPresence()))
            self.settings = settings
            #if DEBUG
            let comparison = materialComparison
            statusItem = StatusItemController(env: env, jobsCard: jobsCard, isPanelVisible: isPanelVisible,
                                              openPanel: { panel.toggle(anchor: $0) }, openSettings: { settings.show() },
                                              openMaterialComparison: { comparison.show(env: env) })
            // `open yabbistir.app --args -materialComparison YES` opens it directly.
            if UserDefaults.standard.bool(forKey: "materialComparison") { comparison.show(env: env) }
            #else
            statusItem = StatusItemController(env: env, jobsCard: jobsCard, isPanelVisible: isPanelVisible,
                                              openPanel: { panel.toggle(anchor: $0) }, openSettings: { settings.show() })
            #endif
            if let statusItem {
                let effects = PreferenceEffects(preferences: env.preferences, env: env, statusItem: statusItem)
                effects.start()
                self.effects = effects
            }
            // Extensions' notices go over the open panel, else under the status item (and its job card).
            env.hostServices.panelFrame = { [weak panel] in panel?.frameOnScreen }
            env.hostServices.underStatusItem = { [weak jobsCard] size in jobsCard?.noticeOrigin(for: size) ?? .zero }
            GlobalShortcuts.onTogglePanel { panel.toggle() }
            env.onIngested = { [weak stack] item in stack?.captured(item) }
            env.isStackOpen = { [weak stack] in stack?.session.isOpen ?? false }
            GlobalShortcuts.onStackCopy { stack.copyIntoStack() }
            GlobalShortcuts.onStackPaste { stack.claimedPastePressed() }
            GlobalShortcuts.onRail(first: { stack.session.moveRecent(to: 0) }, second: { stack.session.moveRecent(to: 1) })
            if OnboardingModel.shouldShowAtLaunch(onboarded: env.preferences.onboarded, historyIsEmpty: historyWasEmpty) {
                // A new install: the first-run window asks for Accessibility itself, in its own words.
                onboarding.show()
            } else {
                // Someone who already has a history needs no first run; it stays one click away in About.
                if !env.preferences.onboarded { env.preferences.onboarded = true }
                // Ask once at launch.
                if !AccessibilityPermission.isTrusted() { AccessibilityPermission.prompt() }
            }
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    /// Opening yabbistir again (Spotlight, Finder) opens Settings: the way in while the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.show()
        return true
    }

    /// A text file shipped in the app bundle ("Name.ext"), or nil when it is missing or unreadable.
    nonisolated private static func bundledText(named fileName: String) -> String? {
        let baseName = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        return Bundle.main.url(forResource: baseName, withExtension: fileExtension.isEmpty ? nil : fileExtension)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// A secret still on the clipboard gives it back before anything else. Jobs end with the app: every
    /// waiting or running one is cancelled, then both helpers are stopped (SIGTERM; they stop their
    /// tools' process groups) before the app exits, so no download runs on without it.
    func applicationWillTerminate(_ notification: Notification) {
        env?.sensitivePaste.flush()
        env?.jobs?.cancelAll()
        env?.stopExtensionHosts()
    }
}
