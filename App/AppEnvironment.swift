import AppKit
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabPasteboard
import YabPlatform
import YabUI

/// Long-lived app objects: storage, the search index, pasteboard capture and paste.
@MainActor
final class AppEnvironment {
    let library: Library
    let language = LanguageStore()
    /// Built-ins from the app bundle; the person's copies and development links in
    /// Application Support/yabbistir/Extensions, their data in …/ExtensionData.
    let extensionRegistry: ExtensionRegistry
    let extensionSettings = ExtensionSettings()
    let extensionLogs = ExtensionLogBuffer()
    /// The signed extension catalog, saved in Application Support/yabbistir/Store. It reaches the network only from
    /// Settings → Extensions → Store, never at launch.
    let storeClient: StoreClient
    /// Talks to the helper program that runs extensions (Contents/MacOS/yabbistir-extension-host).
    let extensionClient: ExtensionHostClient
    /// A second copy of that helper, for jobs alone: a hint that runs out of time restarts its
    /// helper, and that must never cut a download short.
    let jobClient: ExtensionHostClient
    /// The two helpers' processes, stopped by hand when the app quits.
    private let hostTransport: ProcessTransport
    private let jobTransport: ProcessTransport
    let extensions: ExtensionService
    /// What extensions ask of the app (notices, links, history, the on-device model, translation): checked by
    /// `hostCalls`, then done by `hostServices`. Both helpers' requests come here.
    let hostServices: AppHostServices
    let hostCalls: HostCallRouter
    /// Extension sources' rows (a vault's entries), in the app's memory only: forgotten when the Mac locks or sleeps,
    /// and a source's when its extension can no longer run.
    let sources: SourceCenter
    /// The screen locked, the Mac or its displays went to sleep, or another user took over: `sources` forgets every row.
    private let sessionLock: SessionLockObserver
    /// Long actions (downloads): queued, shown on the card under the menu bar icon, delivered once.
    /// Set at launch once the panel and the Sıra exist (`AppJobEnvironment` asks them).
    var jobs: JobCenter!
    /// Image results as files (Application Support/yabbistir/Outputs), kept while history has them.
    let resultFiles: ResultFiles
    private(set) var monitor: PasteboardMonitor!
    /// Between the monitor and history: copies go past the capture rules first.
    private var capture: CapturePipeline!
    private var ingestQueue: IngestQueue!
    private var purgeTimer: Timer?
    /// Every captured copy, after the library has it (the Sıra appends from here).
    var onIngested: ((ClipItem) -> Void)?
    /// Whether the Sıra is open: a capture rule's clean copy then leaves the clipboard (the Sıra's head) alone.
    var isStackOpen: (() -> Bool)?

    /// The one call to the network the app makes on its own account, and only from "Check for Updates…": the result
    /// comes back as a notice (over the open panel, else under the menu bar icon).
    func checkForUpdates() async {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let kind: NoticeKind = switch await UpdateChecker(current: version).check() {
        case .upToDate(let current): .upToDate(version: current)
        case .available(let version, let page): .updateAvailable(version: version, page: page)
        case .failed: .updateCheckFailed
        }
        hostServices.show(kind)
    }

    init() throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yabbistir", isDirectory: true)
        library = try Library(store: ItemStore(directory: directory))
        let warningLogs = extensionLogs
        extensionRegistry = ExtensionRegistry(builtInRoot: Bundle.main.resourceURL!.appendingPathComponent("BuiltinExtensions"),
                                              userRoot: directory.appendingPathComponent("Extensions", isDirectory: true),
                                              dataRoot: directory.appendingPathComponent("ExtensionData", isDirectory: true),
                                              settings: extensionSettings,
                                              onWarning: { id, line in warningLogs.append(id, line) })
        resultFiles = ResultFiles(root: directory.appendingPathComponent("Outputs", isDirectory: true))
        // A version that cannot be read meets no extension's minimum: when in doubt, nothing new is installed.
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { SemanticVersion($0) }
        storeClient = StoreClient(cacheFolder: directory.appendingPathComponent("Store", isDirectory: true), registry: extensionRegistry,
                                  appVersion: appVersion ?? SemanticVersion("0.0.0")!)
        let logs = extensionLogs
        let helper = Bundle.main.url(forAuxiliaryExecutable: "yabbistir-extension-host")!
        hostTransport = ProcessTransport(executableURL: helper)
        jobTransport = ProcessTransport(executableURL: helper)
        extensionClient = ExtensionHostClient(transport: hostTransport, onLog: { id, line in logs.append(id, line) })
        jobClient = ExtensionHostClient(transport: jobTransport, onLog: { id, line in logs.append(id, line) })
        // Tools (`requires.tools`) are looked for in Homebrew's folders first: an app started from
        // the Dock has only the system's PATH.
        extensions = ExtensionService(registry: extensionRegistry, client: extensionClient, jobClient: jobClient, library: library,
                                      settings: extensionSettings, language: language, toolSearchPath: ToolLocator.standard.searchPath,
                                      resultFiles: resultFiles)
        // Wired before anything loads: the main helper and the jobs' one both ask through `hostCalls`, which
        // `installHostCalls` also gives the app's language.
        let hostServices = AppHostServices(extensions: extensions, language: language)
        self.hostServices = hostServices
        hostCalls = HostCallRouter(services: hostServices, registry: extensionRegistry)
        hostCalls.onTranslationNeeded = { [weak hostServices] from, to in hostServices?.offerTranslation(from: from, to: to) }
        extensions.installHostCalls(hostCalls)
        let sources = SourceCenter(service: extensions)
        self.sources = sources
        sessionLock = SessionLockObserver { [weak sources] in sources?.clearAll() }
        // Whoever else follows registry changes (the panel) chains onto this one.
        extensions.onExtensionsChanged = { [weak sources] in sources?.sourcesChanged() }
        ingestQueue = IngestQueue(store: library.store) { [weak self] item in
            guard let self else { return }
            library.didIngest(item)
            // Detectors tag the copy in the background; the tag appears when they answer.
            if let id = item.id { Task { await self.extensions.detect(itemID: id) } }
            onIngested?(item)
        }
        let queue: IngestQueue = ingestQueue
        capture = CapturePipeline(
            rules: CaptureRuleRunner(service: extensions, registry: extensionRegistry, settings: extensionSettings),
            ingest: { clip, saved in queue.submit(clip, then: saved) },
            // The clean copy's own write is not captured again.
            pasteboard: SystemCleanWriter { [weak self] changeCount in self?.monitor.ignore(changeCount: changeCount) },
            stack: { [weak self] in self?.isStackOpen?() ?? false },
            categories: LibraryCategories(library: library),
            log: { line in logs.append("", line) })
        monitor = PasteboardMonitor(reader: SystemPasteboardReader(), apps: WorkspaceAppProvider(), filter: CaptureFilter()) { [weak self] clip, changeCount in
            // Another app's copy (the app's own writes never get here) takes the clipboard from a
            // job result waiting there. Told at capture, before the rules and the ingest: a job that
            // becomes ready meanwhile writes after this copy and keeps its card.
            self?.jobs?.clipboardChanged()
            self?.capture.submit(clip, changeCount: changeCount)
        }
    }

    func start() {
        monitor.start()
        purge()
        // Work folders a quit or a crash left behind mid-call (a half-done download can be gigabytes):
        // every one made before this launch, as no helper runs yet. Off the main thread, it touches the disk.
        let launch = Date()
        Task.detached(priority: .utility) { WorkFolders.purge(olderThan: launch) }
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
    }

    /// ⌘C in the panel: puts the item on the clipboard with every representation, or its plain text
    /// alone (`plainTextOnly`); not re-captured.
    func copyToClipboard(_ itemID: Int64, plainTextOnly: Bool = false) {
        guard let representations = try? library.store.representations(of: itemID) else { return }
        monitor.ignore(changeCount: SystemPasteboardWriter().write(representations, plainTextOnly: plainTextOnly))
        markUsed(itemID)
    }

    /// A paste or copy from the panel counts as a use: renews retention, moves to the top.
    func markUsed(_ itemID: Int64) {
        try? library.markUsed(itemID, at: Date())
    }

    /// Expired history goes, then extension results over the Outputs limit (a result also trims as it joins history,
    /// `ExtensionService.ingestResult`), then the result folders nothing points at any more.
    func purge() {
        try? library.purgeExpired(policy: .default, now: Date())
        Task {
            await extensions.trimOutputs()
            // Result files go with their history items (never all of them on a failed read).
            if let referenced = try? library.store.referencedFileURLs() {
                resultFiles.clean(keeping: referenced, before: Date().addingTimeInterval(-60))
            }
        }
    }

    /// An extension's result joins history (`ExtensionService.ingestResult`); nil when history cannot take it.
    func ingestExtensionResult(_ representations: [[PasteboardRepresentation]], from extensionName: String) -> ClipItem? {
        extensions.ingestResult(representations, from: extensionName)
    }

    /// Quitting: both helpers get SIGTERM at once, stop their tools' process groups (`yab.exec`)
    /// and exit; one still there 200 ms later gets SIGKILL. Waits for both, at most a second.
    func stopExtensionHosts() {
        let stopping = DispatchGroup()
        for transport in [hostTransport, jobTransport] {
            DispatchQueue.global(qos: .userInitiated).async(group: stopping) { transport.stop() }
        }
        _ = stopping.wait(timeout: .now() + 1)
    }

    /// Built per paste so a keyboard-layout switch since launch is honored.
    func makePaster() -> Paster {
        Paster(writer: SystemPasteboardWriter(), resolver: .currentASCIICapable(), poster: CGEventKeystrokePoster(),
               isTrusted: AccessibilityPermission.isTrusted,
               didWrite: { [weak self] changeCount in self?.monitor.ignore(changeCount: changeCount) })
    }
}
