import Foundation
import ImageIO
import Observation
import YabCore
import YabExtensionKit
import YabLocalization

/// The app's door to extensions: builds the catalog, turns clipboard items into extension items,
/// loads extensions into the host when first needed and keeps a panel session's outputs, so the
/// value a row shows is the value that gets pasted.
@MainActor @Observable
public final class ExtensionService: ExtensionCommandsProviding {
    public static let hintTimeout: Duration = .milliseconds(500)
    /// A command the person started, or a source's row action.
    public static let runTimeout: Duration = .seconds(10)
    /// A source's list, asked as the panel opens (the panel never waits for it).
    public static let listTimeout: Duration = .seconds(10)

    public let registry: ExtensionRegistry
    @ObservationIgnored public let client: ExtensionHostClient
    /// Where jobs run: a host of their own, so another call's timeout (which restarts its host)
    /// never cuts a download short. The main client when none is given.
    @ObservationIgnored public let jobClient: ExtensionHostClient
    @ObservationIgnored public var onHintsChanged: (() -> Void)?
    /// The registry changed (installed, removed, turned on or off, edited).
    @ObservationIgnored public var onExtensionsChanged: (() -> Void)?
    /// The app's jobs: an extension that can no longer run (turned off, also after repeated errors;
    /// removed; waiting for consent; behind the master switch) loses its waiting and running ones
    /// whenever the registry changes.
    @ObservationIgnored public weak var jobs: JobCenter?
    /// An extension failed too often and was turned off (it shows as off in Settings).
    @ObservationIgnored public var onExtensionTurnedOff: ((String) -> Void)?
    /// The app results go to. A call keeps the one it started with. Outputs are kept per target, so
    /// a new one never shows the last one's, and letting it go (the panel hid) keeps the value a row
    /// showed for the command that closed the panel; a hint that lands once the target is another
    /// is dropped.
    @ObservationIgnored public var target: TargetInfo?
    @ObservationIgnored let library: Library
    @ObservationIgnored let settings: ExtensionSettings
    @ObservationIgnored let languageStore: LanguageStore
    /// Where extensions' `requires.tools` are looked for, in order.
    @ObservationIgnored let toolSearchPath: [String]
    /// Adopts the files a command returns into `Outputs`; without it a file result fails.
    @ObservationIgnored let resultFiles: ResultFiles?
    /// How long a source's list and its row actions get (`listTimeout`, `runTimeout`; tests make them short).
    @ObservationIgnored let sourceTimeouts: (list: Duration, run: Duration)
    @ObservationIgnored private var catalogCache: (language: String, revision: Int, catalog: CommandCatalog)?
    @ObservationIgnored private var sourceCache: (language: String, revision: Int, sources: SourceCatalog)?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var outputs: [String: ExtensionResult] = [:]
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    /// What each host has loaded, by client.
    @ObservationIgnored private var loaded: [ObjectIdentifier: Set<String>] = [:]
    /// Loads on their way, by host and extension: whoever needs one waits for that same load, and it runs to its
    /// end whoever stops waiting (a rule skipped for a slow first load finds it loaded on a later copy).
    @ObservationIgnored private var loading: [LoadKey: PendingLoad] = [:]
    /// The main host stopped on its own and nothing has loaded in it since. If it stops again before something
    /// does, it may stop on every load: restarts load nothing more by themselves until a load works or the
    /// registry changes.
    @ObservationIgnored private var exitedSinceLoad = false
    /// Extensions whose index.js failed to load: out of the panel until their files change.
    @ObservationIgnored private var loadFailed: Set<String> = []
    @ObservationIgnored private var items: [Int64: ExtensionItem] = [:]
    /// Detector validations sent to the host (tests count them).
    @ObservationIgnored private(set) var validateCalls = 0
    /// Hint runs sent to the host (tests count them).
    @ObservationIgnored private(set) var speculativeCalls = 0
    static let detectorTimeout: Duration = .milliseconds(500)
    static let backfillPage = 200
    /// Text past this size gets no speculative work (hints, detector checks, preview sections)
    /// and travels without its rich text: shipping it would cost more than anyone would wait.
    nonisolated public static let speculativeLimit = 256 * 1024

    public init(registry: ExtensionRegistry, client: ExtensionHostClient, jobClient: ExtensionHostClient? = nil, library: Library,
                settings: ExtensionSettings, language: LanguageStore, toolSearchPath: [String] = [], resultFiles: ResultFiles? = nil,
                sourceTimeouts: (list: Duration, run: Duration) = (ExtensionService.listTimeout, ExtensionService.runTimeout)) {
        self.registry = registry
        self.client = client
        self.jobClient = jobClient ?? client
        self.library = library
        self.settings = settings
        self.languageStore = language
        self.toolSearchPath = toolSearchPath
        self.resultFiles = resultFiles
        self.sourceTimeouts = sourceTimeouts
        registry.onChange = { [weak self] in self?.registryChanged() }
        // Off for real: the switch in Settings shows it, its commands leave, and turning it back
        // on gives it a clean slate. A job counts only when the extension is broken (see the client).
        for host in hosts {
            host.onExtensionDisabled = { [weak self] id in
                self?.registry.setEnabled(id, false)
                self?.onExtensionTurnedOff?(id)
            }
            host.onHostRestarted = { [weak self, weak host] exited in
                guard let self, let host else { return }
                hostRestarted(host, exited: exited)
            }
        }
    }

    /// The main client, and the jobs' own when there is one.
    private var hosts: [ExtensionHostClient] { jobClient === client ? [client] : [client, jobClient] }

    /// Extensions' requests to the app, from either host, go to `router`, which names them in the app's language.
    public func installHostCalls(_ router: HostCallRouter) {
        router.language = { [weak self] in self?.language ?? AppLanguage.default.rawValue }
        for host in hosts {
            host.onHostCall = { call throws(ExtensionError) in try await router.handle(call) }
        }
    }

    public var language: String { languageStore.language.rawValue }

    public var catalog: CommandCatalog {
        if let cache = catalogCache, cache.language == language, cache.revision == revision { return cache.catalog }
        let catalog = CommandCatalog(installed: registry.installed, language: language)
        catalogCache = (language, revision, catalog)
        return catalog
    }

    // MARK: ExtensionCommandsProviding

    public func commands(matching query: String, subjectID: Int64?) -> [ExtensionCommand] {
        catalog.commands(matching: query, subject: subjectID.flatMap { item(for: $0, includeImage: false) }, target: target)
            .filter { !loadFailed.contains($0.extensionID) }
    }

    public func transforms(forItemID itemID: Int64) -> [ExtensionCommand] {
        guard let item = item(for: itemID, includeImage: false) else { return [] }
        return catalog.transforms(for: item, target: target).filter { !loadFailed.contains($0.extensionID) }
    }

    public func hint(for command: ExtensionCommand, subjectID: Int64?) -> String? {
        guard command.input == .item, command.hint else { return command.subtitle }
        guard isSpeculative(command, subjectID: subjectID) else { return command.subtitle }
        return outputs[key(command, subjectID, target)].flatMap(Self.oneLine)
    }

    public func runsAhead(_ command: ExtensionCommand, subjectID: Int64?) -> Bool {
        command.hint && isSpeculative(command, subjectID: subjectID)
    }

    /// Whether a command may run before it is asked for: never on pixels, never on huge text, never
    /// when it makes files (a run ahead would litter work folders and Outputs), and never as a job
    /// (it is long and the person starts it).
    private func isSpeculative(_ command: ExtensionCommand, subjectID: Int64?) -> Bool {
        guard command.output != .file, command.output != .files, !command.isJob else { return false }
        guard command.input == .item else { return true }
        guard !command.needsImage, let subjectID, let item = item(for: subjectID, includeImage: false) else { return false }
        return Self.isLight(item)
    }

    nonisolated private static func isLight(_ item: ExtensionItem) -> Bool {
        (item.text?.utf8.count ?? 0) <= speculativeLimit && !item.isImageFile
    }

    public func requestHints(for commands: [ExtensionCommand], subjectID: Int64?) {
        let target = target
        for command in commands where command.hint && isSpeculative(command, subjectID: subjectID) {
            let key = key(command, subjectID, target)
            guard outputs[key] == nil, !inFlight.contains(key), !failed.contains(key) else { continue }
            inFlight.insert(key)
            speculativeCalls += 1
            Task { [weak self] in
                guard let self else { return }
                let output: ExtensionResult?
                do throws(ExtensionError) {
                    // Ahead of use, so nobody started it: no network, no programs.
                    output = try await run(command, subjectID: subjectID, trigger: .search, effects: false, timeout: Self.hintTimeout,
                                           target: target)
                } catch {
                    output = nil
                }
                inFlight.remove(key)
                // Made for another target than the one now: not kept. (The panel can close and open
                // again for the same app while it is on its way; then it is that session's.)
                guard self.target == target else { return }
                if let output { outputs[key] = output } else { failed.insert(key) }
                onHintsChanged?()
            }
        }
    }

    public func cachedOutput(of command: ExtensionCommand, subjectID: Int64?) -> ExtensionResult? {
        outputs[key(command, subjectID, target)]
    }

    public func output(of command: ExtensionCommand, subjectID: Int64?) async throws(ExtensionError) -> ExtensionResult {
        try await output(of: command, subjectID: subjectID, target: target)
    }

    /// For `target`, whatever the current one is: the panel hands in the target it opened for, and
    /// the value a row showed for it is used as is, even after the panel let the target go.
    public func output(of command: ExtensionCommand, subjectID: Int64?, target: TargetInfo?) async throws(ExtensionError) -> ExtensionResult {
        let key = key(command, subjectID, target)
        if let cached = outputs[key] {
            // A generator makes a new value next time.
            if command.input == .none { outputs[key] = nil }
            return cached
        }
        // The person pasted or copied it (↵, ⌘C, ⌘1–9, the ⇧ panel, ⌘K): the network and programs are allowed.
        let result = try await run(command, subjectID: subjectID, trigger: .search, effects: true, timeout: Self.runTimeout, target: target)
        return try await adopting(result)
    }

    /// A job the person started: in the jobs' own host, with the network and programs, without a
    /// time limit, for the target it started with. Cancelling the calling Task ends it.
    public func runJob(_ command: ExtensionCommand, subjectID: Int64?, target: TargetInfo?,
                       progress: @escaping @MainActor (Double?, String?) -> Void) async throws(ExtensionError) -> ExtensionResult {
        let result = try await run(command, subjectID: subjectID, trigger: .search, effects: true, timeout: nil, target: target,
                                   on: jobClient) { fraction, message in progress(fraction, message) }
        return try await adopting(result)
    }

    /// A file result's files move from the call's work folder into Outputs; the answer carries their new paths.
    private func adopting(_ result: ExtensionResult) async throws(ExtensionError) -> ExtensionResult {
        let paths: [String]
        switch result {
        case .file(let path): paths = [path]
        case .files(let list): paths = list
        default: return result
        }
        // The helper keeps the work folder for the app to adopt: when that fails, the folder goes now.
        let workRoot = resultFiles?.workRoot ?? WorkFolders.root
        guard let files = resultFiles else {
            WorkFolders.remove(holding: paths, in: workRoot)
            throw ExtensionError(.unavailable, "files cannot be kept here")
        }
        let adopted = await Task.detached(priority: .userInitiated) { () -> Result<[URL], ExtensionError> in
            do throws(ExtensionError) { return .success(try files.adopt(paths)) } catch { return .failure(error) }
        }.value
        if case .failure = adopted { WorkFolders.remove(holding: paths, in: workRoot) }
        return .files(paths: try adopted.get().map(\.path))
    }

    public func resetSession() {
        outputs = [:]
        failed = []
        items = [:]
    }

    // MARK: Results in history

    /// An extension's result joins history from "yabbistir · <extension>" (detectors tag it in the
    /// background); nil when history cannot take it. One with files counts toward the Outputs limit at once
    /// (`trimOutputs()`), never at its own cost: the limit holds between purges too.
    public func ingestResult(_ representations: [[PasteboardRepresentation]], from extensionName: String) -> ClipItem? {
        guard !representations.isEmpty else { return nil }
        let clip = CapturedClip(items: representations, source: SourceApp(bundleID: "dev.yabbistir.app", name: "yabbistir · \(extensionName)"),
                                device: .local, capturedAt: Date())
        guard let ingested = try? library.store.ingest(clip), let itemID = ingested.item.id else { return nil }
        library.didIngest(ingested.item)
        Task { await detect(itemID: itemID) }
        if representations.contains(where: { $0.contains { $0.type == TypeIdentifiers.fileURL } }) {
            Task { await trimOutputs() }
        }
        return ingested.item
    }

    /// How long a result counts as just in: no trim takes it then, however full Outputs is (it is about to be pasted or
    /// copied, or another result's trim runs meanwhile).
    nonisolated public static let freshResultAge: TimeInterval = 60

    /// Extension result files over the Outputs limit (`ExtensionSettings.outputsLimitBytes`): the oldest results in no
    /// category leave history (their folders go with the next `ResultFiles.clean`, as nothing points at them then).
    /// Results that joined history in the last `freshResultAge` seconds are never among them. History and the files'
    /// sizes are read off the main actor.
    public func trimOutputs() async {
        guard let files = resultFiles else { return }
        let (store, limit) = (library.store, settings.outputsLimitBytes)
        let freshSince = Date().addingTimeInterval(-Self.freshResultAge)
        let over = await Task.detached(priority: .utility) {
            Self.overLimit(store: store, files: files, limit: limit, freshSince: freshSince)
        }.value
        for id in over { _ = try? library.deleteFromHistory(id) }
    }

    nonisolated private static func overLimit(store: ItemStore, files: ResultFiles, limit: Int64, freshSince: Date) -> [Int64] {
        let outputs = files.root.resolvingSymlinksInPath().path + "/"
        guard let all = try? store.resultFileItems() else { return [] }
        let items: [(itemID: Int64, url: URL, date: Date, inCategory: Bool)] = all.compactMap { entry in
            guard let url = URL(string: entry.url), url.isFileURL, url.resolvingSymlinksInPath().path.hasPrefix(outputs) else { return nil }
            // Kept like a result in a category: it counts toward the size, and is never chosen.
            let kept = entry.date >= freshSince || ((try? store.categoryIDs(ofItem: entry.itemID)) ?? []).isEmpty == false
            return (entry.itemID, url, entry.date, kept)
        }
        return ResultFiles.overLimit(bytes: limit, items: items)
    }

    // MARK: Items

    /// A clipboard item as extensions see it, from only the representations it needs: an image's
    /// pixels are read only when an image action runs (and then off the main actor, in `run`).
    public func item(for itemID: Int64, includeImage: Bool) -> ExtensionItem? {
        if !includeImage, let cached = items[itemID] { return cached }
        guard let item = Self.buildItem(itemID, store: library.store, includeImage: includeImage) else { return nil }
        if !includeImage { items[itemID] = item }
        return item
    }

    /// `yab.history.recent`: history's newest items, at most `limit` (never more than `HostCallRouter.historyLimit`).
    public func historyItems(recent limit: Int) async -> [ExtensionItem] {
        await historyItems(matching: "", limit: limit)
    }

    /// Called once per history item, on the thread that builds it. Lets a test see that the build is not on the main actor.
    @ObservationIgnored var historyBuildObserver: (@Sendable () -> Void)?

    /// `yab.history.search`: what the panel's history search finds for `query`, newest first, at most `limit`.
    /// Built as any item, but never with an image's pixels (not even read), and outside the panel session's cache.
    /// The index answers on the main actor; reading and building the items (the database, the full texts) does not.
    public func historyItems(matching query: String, limit: Int) async -> [ExtensionItem] {
        let limit = min(max(limit, 0), HostCallRouter.historyLimit)
        guard limit > 0 else { return [] }
        let ids = library.index.search(query, limit: limit).ids
        let store = library.store
        let observer = historyBuildObserver
        return await Task.detached(priority: .userInitiated) {
            ids.compactMap { id -> ExtensionItem? in
                observer?()
                return Self.buildItem(id, store: store, includeImage: false)?.cappedForHistory()
            }
        }.value
    }

    nonisolated private static let imageTypes = [TypeIdentifiers.png, TypeIdentifiers.tiff, TypeIdentifiers.jpeg, TypeIdentifiers.heic]

    nonisolated private static func buildItem(_ itemID: Int64, store: ItemStore, includeImage: Bool) -> ExtensionItem? {
        guard let clip = try? store.item(id: itemID) else { return nil }
        let wanted: Set<String> = switch clip.kind {
        case .text, .code: [TypeIdentifiers.plainText, ResultRepresentations.html]
        case .link: [TypeIdentifiers.url, TypeIdentifiers.plainText, ResultRepresentations.html]
        case .color: []
        case .image: includeImage ? Set(imageTypes) : []
        case .file: [TypeIdentifiers.fileURL]
        }
        let representations = (try? store.representations(of: itemID, types: wanted)) ?? []
        var item = extensionItem(id: itemID, kind: clip.kind, representations, text: clip.searchText, preview: clip.previewText,
                                 copiedAt: clip.lastCopiedAt, includeImage: includeImage)
        item.source = .init(name: clip.sourceName, bundleID: clip.sourceBundleID, device: clip.device.rawValue)
        item.tags = ((try? store.tags(ofItem: itemID)) ?? []).map { "\($0.extensionID):\($0.tag)" }
        return item
    }

    /// What a copy's representations show an extension, the part its kind needs being enough: a stored item's, or a
    /// new copy's on its way to history (`CapturePipeline`). `text` stands in for a text that has no plain text,
    /// `preview` is the line its row shows. Without source and tags.
    nonisolated static func extensionItem(id: Int64, kind: ItemKind, _ representations: [[PasteboardRepresentation]],
                                          text: @autoclosure () -> String, preview: String, copiedAt: Date,
                                          includeImage: Bool) -> ExtensionItem {
        let first = representations.first ?? []
        func data(_ type: String) -> Data? { first.first { $0.type == type }?.data }
        func string(_ type: String) -> String? { data(type).map { String(decoding: $0, as: UTF8.self) } }

        var item = ExtensionItem(id: id, kind: kind.rawValue, copiedAt: copiedAt)
        switch kind {
        case .text, .code:
            item.text = string(TypeIdentifiers.plainText) ?? text()
        case .link:
            item.url = string(TypeIdentifiers.url) ?? string(TypeIdentifiers.plainText) ?? preview
            item.text = item.url
        case .color:
            item.text = preview
            if let color = ColorValue(hex: preview) {
                item.color = .init(hex: color.hex, r: color.red, g: color.green, b: color.blue, a: 1)
            }
        case .image:
            if includeImage { item.image = imagePayload(imageTypes.compactMap(data)) }
        case .file:
            item.files = representations.compactMap { representation in
                guard let raw = representation.first(where: { $0.type == TypeIdentifiers.fileURL })?.data,
                      let url = URL(dataRepresentation: raw, relativeTo: nil) else { return nil }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                return .init(path: url.path, name: url.lastPathComponent, size: values?.fileSize ?? 0,
                             uti: values?.contentType?.identifier ?? "public.data")
            }
            // A picture copied as a file: image actions read it from disk (gone or unreadable: nil).
            if includeImage, item.isImageFile, let path = item.files?.first?.path,
               let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                item.image = imagePayload([bytes])
            }
        }
        if let html = data(ResultRepresentations.html), html.count <= speculativeLimit {
            item.richText = .init(html: String(decoding: html, as: UTF8.self))
        }
        return item
    }

    /// The first candidate that decodes, as PNG bytes (PNG is passed through as it is).
    nonisolated private static func imagePayload(_ candidates: [Data]) -> ExtensionItem.ImagePayload? {
        for data in candidates {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            if CGImageSourceGetType(source) as String? == TypeIdentifiers.png { return .init(data: data, width: image.width, height: image.height) }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, TypeIdentifiers.png as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { continue }
            return .init(data: png as Data, width: image.width, height: image.height)
        }
        return nil
    }

    // MARK: Detectors

    /// Tags a new copy: each usable detector whose kinds and pattern match it (checked here) and
    /// whose `validate` agrees (in the extension). Detectors never reach the network.
    public func detect(itemID: Int64, extensions only: Set<String>? = nil) async {
        await detect(itemID: itemID, extensions: only, keepsItem: true)
    }

    /// `keepsItem: false`: the launch scan leaves the session cache as it found it.
    private func detect(itemID: Int64, extensions only: Set<String>?, keepsItem: Bool) async {
        guard let item = item(for: itemID, includeImage: false) else { return }
        if !keepsItem { items[itemID] = nil }
        guard Self.isLight(item) else { return }
        let catalog = catalog
        var changed = false
        for installed in registry.installed where installed.isUsable && !loadFailed.contains(installed.id) && (only?.contains(installed.id) ?? true) {
            guard let manifest = installed.manifest, !manifest.contributes.detectors.isEmpty else { continue }
            var tags: [StoredTag] = []
            for detector in manifest.contributes.detectors where catalog.accepts(detector.accepts, item) {
                if detector.validate {
                    guard await validate(item, detector: detector.id, in: installed) else { continue }
                }
                tags.append(StoredTag(extensionID: installed.id, tag: detector.id))
            }
            let before = (try? library.store.tags(ofItem: itemID).filter { $0.extensionID == installed.id }) ?? []
            guard before != tags else { continue }
            try? library.store.setTags(tags, for: itemID, extensionID: installed.id)
            changed = true
        }
        guard changed else { return }
        items[itemID] = nil
        library.tagsChanged([itemID])
    }

    /// Runs detectors that have not yet seen the whole history (new, or a new version) over it,
    /// a page at a time.
    public func backfill() async {
        let pending = registry.installed.filter { installed in
            guard installed.isUsable, let manifest = installed.manifest, !manifest.contributes.detectors.isEmpty else { return false }
            return settings.scannedDetectorVersion(installed.id) != manifest.version
        }
        guard !pending.isEmpty else { return }
        let ids = Set(pending.map(\.id))
        // Only kinds some pending detector takes are read at all (an image file counts as image).
        let kinds = Set(pending.flatMap { $0.manifest?.contributes.detectors.flatMap(\.accepts.kinds) ?? [] })
        var cursor: Int64?
        while let page = try? library.store.itemIDs(after: cursor, limit: Self.backfillPage), let last = page.last {
            for itemID in page {
                // One item at a time, then the main actor gets its turn.
                await Task.yield()
                guard let clip = try? library.store.item(id: itemID),
                      kinds.contains(clip.kind.rawValue) || (clip.kind == .file && kinds.contains("image")) else { continue }
                await detect(itemID: itemID, extensions: ids, keepsItem: false)
            }
            cursor = last
        }
        for installed in pending { if let version = installed.manifest?.version { settings.setScannedDetectorVersion(installed.id, version) } }
    }

    public func previewSections(itemID: Int64) async -> [PreviewSection] {
        let target = target
        guard let item = item(for: itemID, includeImage: false), Self.isLight(item) else { return [] }
        var sections: [PreviewSection] = []
        for installed in registry.installed where installed.isUsable {
            guard let manifest = installed.manifest else { continue }
            for detector in manifest.contributes.detectors where detector.preview && item.tags.contains("\(installed.id):\(detector.id)") {
                do throws(ExtensionError) {
                    try await load(installed)
                    let output = try await client.invoke(installed.id, .preview, name: detector.id, item: item,
                                                         context: context(installed, trigger: .preview, target: target), effects: false,
                                                         timeout: Self.hintTimeout)
                    if case .sections(let found) = output { sections += found }
                } catch {
                    continue
                }
            }
        }
        return sections
    }

    public func tagLabels(_ tags: [StoredTag]) -> [String] {
        tags.compactMap { tag in
            guard let installed = registry.installed.first(where: { $0.id == tag.extensionID && $0.isUsable }),
                  let detector = installed.manifest?.contributes.detectors.first(where: { $0.id == tag.tag }) else { return nil }
            return installed.localization?.string(detector.tag, language: language)
        }
    }

    private func validate(_ item: ExtensionItem, detector: String, in installed: InstalledExtension) async -> Bool {
        let target = target
        do throws(ExtensionError) {
            try await load(installed)
            validateCalls += 1
            let output = try await client.invoke(installed.id, .validate, name: detector, item: item,
                                                 context: context(installed, trigger: .detect, target: target), effects: false,
                                                 timeout: Self.detectorTimeout)
            return output == .valid(true)
        } catch {
            return false
        }
    }

    /// `target`: the one the call started with, read before anything it awaits.
    private func context(_ installed: InstalledExtension, trigger: ExtensionContext.Trigger, variant: String? = nil,
                         target: TargetInfo?) -> ExtensionContext {
        ExtensionContext(language: language, preferences: settings.preferences(installed.id, specs: installed.manifest?.preferences ?? []),
                         trigger: trigger, variant: variant, target: target,
                         readableFolders: settings.chosenFolders(installed.id, specs: installed.manifest?.preferences ?? []))
    }

    // MARK: Running
    //
    // `effects` (the network and programs) only for a run the person started: ↵, ⌘C, ⌘1–9,
    // the ⇧ panel and ⌘K, all through `output(of:subjectID:)`. Hints and runs ahead (`requestHints`),
    // detectors (`validate`) and preview sections never get them.

    private func run(_ command: ExtensionCommand, subjectID: Int64?, trigger: ExtensionContext.Trigger, effects: Bool,
                     timeout: Duration?, target: TargetInfo?, on host: ExtensionHostClient? = nil,
                     onProgress: ((_ fraction: Double?, _ message: String?) -> Void)? = nil) async throws(ExtensionError) -> ExtensionResult {
        let host = host ?? client
        guard let installed = registry.installed.first(where: { $0.id == command.extensionID && $0.isUsable }),
              let manifest = installed.manifest else {
            throw ExtensionError(.notFound, "\(command.extensionName) is not available")
        }
        // A run the person started needs every tool it requires: one that is missing fails it here, in
        // exec's words (the card names the tool), not later in another tool's English (yt-dlp runs ffmpeg itself).
        if effects, let missing = toolLocator.missing(manifest.requires?.tools ?? []).first {
            throw ExtensionError(.toolMissing, "\(missing.name) is not installed. Install it with: \(missing.install)")
        }
        var item: ExtensionItem?
        if command.input == .item {
            var built: ExtensionItem?
            if command.needsImage, let subjectID {
                // Pixels can be tens of megabytes: read and encoded away from the main actor.
                let store = library.store
                built = await Task.detached(priority: .userInitiated) { Self.buildItem(subjectID, store: store, includeImage: true) }.value
            } else if let subjectID {
                built = self.item(for: subjectID, includeImage: false)
            }
            guard let built else { throw ExtensionError(.notFound, "the item is no longer in history") }
            item = built
        }
        try await load(installed, into: host)
        let output = try await host.invoke(installed.id, .run, name: command.actionID, item: item,
                                           context: context(installed, trigger: trigger, variant: command.variant, target: target),
                                           effects: effects, timeout: timeout, onProgress: onProgress)
        guard case .result(let result) = output else { throw ExtensionError(.badResult, "run returned no result") }
        return result
    }

    /// Where required tools are looked for: the search path the host gets, or the standard one (as the runtime does).
    private var toolLocator: ToolLocator {
        toolSearchPath.isEmpty ? .standard : ToolLocator(searchPath: toolSearchPath)
    }

    /// `host`: the main client unless a job loads into its own. A caller that is cancelled stops waiting at once;
    /// the load goes on.
    private func load(_ installed: InstalledExtension, into host: ExtensionHostClient? = nil) async throws(ExtensionError) {
        let host = host ?? client
        guard let pending = startLoad(installed, into: host) else { return }
        do throws(ExtensionError) {
            try await pending.wait()
        } catch {
            // It failed loading what may be old code (the registry changed meanwhile, so the failure hid nothing):
            // the caller wants an answer about the code as it is now, which gets one try of its own, unless the
            // code as it is now has already failed (another try would only count against it).
            guard error.code != .cancelled, pending.revision != revision, !loadFailed.contains(installed.id),
                  let current = registry.installed.first(where: { $0.id == installed.id && $0.isUsable }) else { throw error }
            guard let retry = startLoad(current, into: host) else { return }
            try await retry.wait()
        }
    }

    /// The load of `installed` into `host` that is on its way, started here when there is none; nil once it is loaded.
    private func startLoad(_ installed: InstalledExtension, into host: ExtensionHostClient) -> PendingLoad? {
        let key = LoadKey(host: ObjectIdentifier(host), id: installed.id)
        guard loaded[key.host]?.contains(installed.id) != true else { return nil }
        if let pending = loading[key] { return pending }
        // Usable means consent covers the manifest's request, so the host holds it to exactly that.
        let (folder, dataFolder, language, toolSearchPath) = (installed.folder, registry.dataFolder(for: installed.id), language, toolSearchPath)
        let grant = installed.manifest.map { PermissionGrant.requested(by: $0) } ?? .empty
        let secrets = settings.secrets(installed.id, specs: installed.manifest?.preferences ?? [])
        let revision = revision
        let pending = PendingLoad(revision: revision)
        Task { [weak self] in
            let result: Result<Void, ExtensionError>
            do throws(ExtensionError) {
                try await host.load(installed.id, folder: folder, dataFolder: dataFolder, language: language, grant: grant,
                                    toolSearchPath: toolSearchPath, secrets: secrets)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            // A failure hides the extension before anyone waiting hears of it.
            self?.noteLoadFailure(key.id, result, revision: revision)
            if case .success = result { self?.noteLoadWorked(in: host) }
            pending.finish(result)
            // Those who were waiting are woken with the result (the main actor picks the order they go on in,
            // which need not be the order they came); whoever asks after this finds it loaded.
            await Task.yield()
            self?.settle(key, pending, result, revision: revision)
        }
        loading[key] = pending
        return pending
    }

    /// A failed load hides its extension until its files change (being cut short or cancelled is no failure). A load
    /// started before the registry last changed failed with what may be old code: it hides nothing.
    private func noteLoadFailure(_ id: String, _ result: Result<Void, ExtensionError>, revision: Int) {
        guard revision == self.revision, case .failure(let error) = result, error.code != .interrupted, error.code != .cancelled else { return }
        loadFailed.insert(id)
        onHintsChanged?()
    }

    /// A host that loads things is not one that stops on every load.
    private func noteLoadWorked(in host: ExtensionHostClient) {
        if host === client { exitedSinceLoad = false }
    }

    /// A load is over. One started before the registry last changed loaded what may be old code: its extension
    /// loads again on next use.
    private func settle(_ key: LoadKey, _ pending: PendingLoad, _ result: Result<Void, ExtensionError>, revision: Int) {
        guard revision == self.revision, loading[key] === pending else { return }
        loading[key] = nil
        if case .success = result { loaded[key.host, default: []].insert(key.id) }
    }

    /// A host started over or stopped: nothing is loaded in it, and its loads on their way were cut short. Its
    /// extensions load again on next use, through the shared load that no caller's deadline cuts short; those
    /// with capture rules right away (in the main host), so copies find them in. A turn later: a load that itself
    /// ran out of time is recorded as failed first, and not tried again. A host that stopped on its own twice with
    /// nothing loaded in between is not started again this way (it may stop on every load); a later call still
    /// starts it.
    private func hostRestarted(_ host: ExtensionHostClient, exited: Bool) {
        let restarted = ObjectIdentifier(host)
        loaded[restarted] = nil
        loading = loading.filter { $0.key.host != restarted }
        guard host === client else { return }
        if exited {
            guard !exitedSinceLoad else { return }
            exitedSinceLoad = true
        }
        Task { [weak self] in self?.preloadCaptureRules() }
    }

    /// New code or new state: everything loaded goes (in every host), everything cached goes, and the
    /// extensions with capture rules load again right away.
    private func registryChanged() {
        revision += 1
        loadFailed = []
        for host in hosts {
            host.resetAll()
            for id in loaded[ObjectIdentifier(host)] ?? [] { host.unload(id) }
        }
        loaded = [:]
        loading = [:]
        exitedSinceLoad = false
        resetSession()
        let usable = Set(registry.installed.filter(\.isUsable).map(\.id))
        jobs?.cancelJobs { !usable.contains($0.extensionID) }
        onExtensionsChanged?()
        onHintsChanged?()
        preloadCaptureRules()
    }

    // MARK: Capture rules

    /// Runs one capture rule on a new copy: in the main host, as kind `captureRule` with the
    /// `capture` trigger and no effects, so the network, programs and every request that reaches out are refused.
    /// `timeout` is the rule's own limit once its extension is loaded: running out restarts the host and counts
    /// against the extension (`ExtensionHostClient.failureLimit` in a row turn it off). A first load comes before
    /// that clock starts; the caller bounds the whole call (`CaptureRuleRunner`), and cancelling it costs nobody.
    public func runCaptureRule(extensionID: String, rule: String, item: ExtensionItem,
                               timeout: Duration) async throws(ExtensionError) -> CaptureOutcome {
        guard let installed = registry.installed.first(where: { $0.id == extensionID && $0.isUsable }), let manifest = installed.manifest,
              !loadFailed.contains(extensionID) else {
            throw ExtensionError(.unavailable, "\(extensionID) is not available")
        }
        guard manifest.permissions.contains("capture") else {
            throw ExtensionError(.permissionDenied, "\(extensionID) has no capture permission")
        }
        guard manifest.contributes.captureRules.contains(where: { $0.id == rule }) else {
            throw ExtensionError(.notFound, "\(extensionID) has no capture rule \(rule)")
        }
        try await load(installed)
        let output = try await client.invoke(installed.id, .captureRule, name: rule, item: item,
                                             context: context(installed, trigger: .capture, target: nil), effects: false, timeout: timeout)
        guard case .capture(let outcome) = output else { throw ExtensionError(.badResult, "the rule returned no decision") }
        return outcome
    }

    /// Loads every usable extension with capture rules into the main host ahead of the next copy, so it finds
    /// them ready instead of skipping them while their index.js runs: after every registry change, and at
    /// launch. The task ends when those loads have.
    @discardableResult
    public func preloadCaptureRules() -> Task<Void, Never> {
        let pending = registry.installed.filter { installed in
            guard installed.isUsable, !loadFailed.contains(installed.id), let manifest = installed.manifest else { return false }
            return manifest.permissions.contains("capture") && !manifest.contributes.captureRules.isEmpty
        }.compactMap { startLoad($0, into: client) }
        return Task { for load in pending { try? await load.wait() } }
    }

    private func key(_ command: ExtensionCommand, _ subjectID: Int64?, _ target: TargetInfo?) -> String {
        "\(command.id)|\(subjectID ?? 0)|\(target?.bundleID ?? "")"
    }

    private static func oneLine(_ result: ExtensionResult) -> String? {
        let text: String? = switch result {
        case .text(let text): text
        case .html(_, let text): text
        case .link(let url, _): url
        case .image: nil
        // Files never run ahead (see isSpeculative): there is no line to show.
        case .file, .files: nil
        case .none(let message): message
        }
        guard let text else { return nil }
        return String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: Sources
//
// A source's list (the panel opened) and its row actions (the person chose one) are the person's own calls: the
// network and programs are allowed, as for a run they start. What they return goes back to the caller alone: never
// into `outputs`, history, Outputs, a job or a log line (the client logs a bad result's shape, never a value).

extension ExtensionService: SourceServing {
    /// The usable extensions' sources, in the app's language, from manifests alone.
    public var sources: [SourceDescriptor] {
        if let cache = sourceCache, cache.language == language, cache.revision == revision { return cache.sources.descriptors }
        let catalog = SourceCatalog(installed: registry.installed, language: language)
        sourceCache = (language, revision, catalog)
        return catalog.descriptors
    }

    public func list(source key: String) async throws(ExtensionError) -> SourceListing {
        let (installed, descriptor) = try usable(key)
        let output = try await invoke(descriptor, of: installed, .sourceList, source: nil, timeout: sourceTimeouts.list)
        guard case .listing(let listing) = output else { throw ExtensionError(.badResult, "list returned no listing") }
        return listing
    }

    public func run(source key: String, row: String, action actionID: String) async throws(ExtensionError) -> SourceValue {
        let (installed, descriptor) = try usable(key)
        guard let action = descriptor.actions.first(where: { $0.id == actionID }) else {
            throw ExtensionError(.notFound, "\(descriptor.title) has no action \(actionID)")
        }
        let output = try await invoke(descriptor, of: installed, .sourceRun,
                                      source: SourceInvocation(rowID: row, actionID: action.id, kind: action.kind), timeout: sourceTimeouts.run)
        // The helper holds a value to its action's kind; so does the app, as a secret passed off as text would reach
        // the clipboard unconcealed.
        switch output {
        case .value(let value) where value.isKind(action.kind): return value
        default: throw ExtensionError(.badResult, "run returned no value of the action's kind")
        }
    }

    /// The usable extension behind `key`, ready for a call the person started: its code loaded the last time it was
    /// tried, and every tool it requires is here (one that is missing fails it in exec's words).
    private func usable(_ key: String) throws(ExtensionError) -> (InstalledExtension, SourceDescriptor) {
        guard let descriptor = sources.first(where: { $0.id == key }),
              let installed = registry.installed.first(where: { $0.id == descriptor.extensionID && $0.isUsable }),
              let manifest = installed.manifest else {
            throw ExtensionError(.notFound, "\(key) is not available")
        }
        // Not loaded again on every panel open (each failure counts against it) until its files change.
        guard !loadFailed.contains(installed.id) else { throw ExtensionError(.unavailable, "\(descriptor.extensionName) could not load") }
        if let missing = toolLocator.missing(manifest.requires?.tools ?? []).first {
            throw ExtensionError(.toolMissing, "\(missing.name) is not installed. Install it with: \(missing.install)")
        }
        return (installed, descriptor)
    }

    /// In the main host, with the network and programs, for no target: a source's rows are the same wherever they go.
    /// Running out of time aborts the call alone, and no failure of it counts against the extension (the client).
    private func invoke(_ descriptor: SourceDescriptor, of installed: InstalledExtension, _ kind: InvokeKind, source: SourceInvocation?,
                        timeout: Duration) async throws(ExtensionError) -> InvokeOutput {
        try await load(installed)
        return try await client.invoke(installed.id, kind, name: descriptor.sourceID, item: nil,
                                       context: context(installed, trigger: .source, target: nil), effects: true, source: source,
                                       timeout: timeout)
    }
}

private extension SourceValue {
    func isKind(_ kind: SourceActionSpec.Kind) -> Bool {
        switch (self, kind) {
        case (.secret, .secret), (.text, .text): true
        default: false
        }
    }
}

/// One extension in one host.
private struct LoadKey: Hashable {
    let host: ObjectIdentifier
    let id: String
}

/// A load on its way, which whoever needs the extension waits for: all are woken with its result (they go on in
/// whatever order the main actor runs them, not necessarily the order they came), and one that is cancelled stops
/// waiting at once (with `cancelled`) while the load goes on.
@MainActor
private final class PendingLoad {
    /// The registry's revision when it started.
    let revision: Int
    private var result: Result<Void, ExtensionError>?
    private var waiters: [(id: Int, continuation: CheckedContinuation<Result<Void, ExtensionError>, Never>)] = []
    private var nextWaiter = 0

    init(revision: Int) {
        self.revision = revision
    }

    func wait() async throws(ExtensionError) {
        if let result {
            // Just finished: those already woken go first.
            await Task.yield()
            return try result.get()
        }
        let id = nextWaiter
        nextWaiter += 1
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in waiters.append((id, continuation)) }
        } onCancel: {
            Task { @MainActor in self.stopWaiting(id) }
        }
        try outcome.get()
    }

    func finish(_ result: Result<Void, ExtensionError>) {
        self.result = result
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.continuation.resume(returning: result) }
    }

    private func stopWaiting(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: .failure(ExtensionError(.cancelled, "the call was cancelled")))
    }
}

/// The app's jobs run through `runJob`.
extension ExtensionService: JobRunning {
    public func run(_ command: ExtensionCommand, subjectID: Int64?, target: TargetInfo?,
                    progress: @escaping @MainActor (Double?, String?) -> Void) async throws(ExtensionError) -> ExtensionResult {
        try await runJob(command, subjectID: subjectID, target: target, progress: progress)
    }
}
