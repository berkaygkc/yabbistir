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
            let jobsCard = JobsSurfaceController(center: env.jobs, language: env.language)
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
            let settings = SettingsWindowController(model: settingsModel, store: storeModel)
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
            // Extensions' notices go over the open panel, else under the status item (and its job card).
            env.hostServices.panelFrame = { [weak panel] in panel?.frameOnScreen }
            env.hostServices.underStatusItem = { [weak jobsCard] size in jobsCard?.noticeOrigin(for: size) ?? .zero }
            GlobalShortcuts.onTogglePanel { panel.toggle() }
            env.onIngested = { [weak stack] item in stack?.captured(item) }
            env.isStackOpen = { [weak stack] in stack?.session.isOpen ?? false }
            GlobalShortcuts.onStackCopy { stack.copyIntoStack() }
            GlobalShortcuts.onStackPaste { stack.claimedPastePressed() }
            GlobalShortcuts.onRail(first: { stack.session.moveRecent(to: 0) }, second: { stack.session.moveRecent(to: 1) })
            // Ask once at launch.
            if !AccessibilityPermission.isTrusted() { AccessibilityPermission.prompt() }
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
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
