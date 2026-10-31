import Foundation
import Observation
import YabExtensionKit
import YabExtensions
import YabLocalization

/// Settings → Extensions → Store: the signed catalog as rows, the extensions picked to install, one consent for all of
/// them, and updates. The network is reached only through `StoreClient`, and only when the person asks: the first
/// time the tab is shown in a Settings session, Refresh, and Install or Update. The saved catalog shows first.
@MainActor @Observable
public final class StoreModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let description: String
        public let author: String
        public let version: String
        /// The installed version an available update replaces.
        public let fromVersion: String?
        /// An `sf:` symbol. A catalog icon file is never fetched for the list; it shows as a generic symbol.
        public let icon: String
        /// "Network: 3 sites · Runs: yt-dlp, ffmpeg, deno"; empty when it asks for nothing.
        public let permissionSummary: String
        /// The sites behind the summary, for its tooltip.
        public let hosts: [String]
        public let status: EntryStatus
        /// "Installed", "Update available", "Requires a newer yabbistir" or "Built-in"; nil when it can be installed.
        public let statusLabel: String?
        /// Only an extension that is not installed yet and that this app can run is picked for installing.
        public let isSelectable: Bool
        public let isSelected: Bool
        public let isInstalling: Bool
        /// Why the last attempt to install it failed, as the person should read it.
        public let failure: String?
    }

    /// The one sheet shown before anything is downloaded: every extension being installed with what it asks for, or
    /// the updates that ask for something new under "New permissions".
    public struct Consent: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case install, update }

        public struct Item: Identifiable, Equatable, Sendable {
            public let id: String
            public let name: String
            public let icon: String
            public let version: String
            /// The installed version an update replaces.
            public let fromVersion: String?
            /// For an install, everything it asks for; for an update, only what it asks for beyond the approved grant.
            public let sentences: [String]
            /// What approving records: the version's full request, as the sheet shows it. For an install the sentences
            /// describe all of it; for an update they describe the part not approved before, and the rest was approved
            /// earlier.
            public let grant: PermissionGrant
            /// The catalog entry as it was when the sheet was made. Only this exact offer is installed: if the catalog
            /// offers something else under the same id by the time it is confirmed, the item is not installed.
            public let entry: StoreEntry
        }

        public let id: UUID
        public let kind: Kind
        /// New installs, or the updates that ask for something new.
        public let items: [Item]
        /// Updates that ask for nothing new. They are installed with the others and nothing is approved for them.
        public let quietUpdates: [Item]
    }

    public enum InstallFailure: Equatable, Sendable {
        case store(StoreFailure)
        /// A refresh changed the offer (version, permissions, sites, programs or package) after the sheet was shown.
        case changedSinceShown
    }

    /// A line under a list that is still shown: why the latest catalog is not the one on screen.
    public struct Notice: Equatable, Sendable {
        public let symbol: String
        public let text: String
    }

    /// What fills the tab when there is no catalog to show.
    public struct Unavailable: Equatable, Sendable {
        public let symbol: String
        public let title: String
        public let message: String
    }

    public var query = ""
    public var category: ExtensionCategory?
    /// The extensions picked to install. Only rows that can be installed count; see `selectedCount`.
    public var selection: Set<String> = []
    /// Set by Install or Update All; the sheet reads it.
    public var pendingConsent: Consent?
    /// Why an install did not happen, by extension id.
    public private(set) var failures: [String: InstallFailure] = [:]
    public private(set) var installing: Set<String> = []
    /// The refresh under way, if any.
    public private(set) var refreshTask: Task<Void, Never>?
    /// The installs or updates under way, if any.
    public private(set) var installTask: Task<Void, Never>?

    @ObservationIgnored private var refreshedThisSession = false
    @ObservationIgnored private var cacheLoaded = false
    @ObservationIgnored private var isVisible = false

    @ObservationIgnored private let client: StoreClient
    @ObservationIgnored private let registry: ExtensionRegistry
    @ObservationIgnored private let languageStore: LanguageStore

    public init(client: StoreClient, registry: ExtensionRegistry, language: LanguageStore) {
        self.client = client
        self.registry = registry
        self.languageStore = language
    }

    public var language: AppLanguage { languageStore.language }

    private func string(_ key: String, _ arguments: CVarArg...) -> String {
        arguments.isEmpty ? L10n.string(key, language) : String(format: L10n.string(key, language), locale: language.locale, arguments: arguments)
    }

    // MARK: Network

    /// The Store tab became visible. The saved catalog is read first (no network); the first appearance in a Settings
    /// session also refreshes.
    public func appeared() {
        isVisible = true
        if !cacheLoaded {
            cacheLoaded = true
            if client.catalog == nil { client.loadCache() }
        }
        pruneSelection()
        guard !refreshedThisSession else { return }
        refreshedThisSession = true
        refresh()
    }

    public func disappeared() {
        isVisible = false
    }

    /// The Settings window was opened again: the next look at the tab refreshes once more (now, if it is on screen).
    public func beginSession() {
        refreshedThisSession = false
        if isVisible { appeared() }
    }

    /// The Refresh button.
    public func refresh() {
        guard refreshTask == nil else { return }
        let client = client
        refreshTask = Task {
            await client.refresh()
            pruneSelection()
            refreshTask = nil
        }
    }

    public var isRefreshing: Bool { refreshTask != nil || client.lastRefresh == .refreshing }

    // MARK: Rows

    private var entries: [StoreEntry] {
        let language = language
        return (client.catalog?.extensions ?? []).sorted {
            $0.localizedName(language).localizedStandardCompare($1.localizedName(language)) == .orderedAscending
        }
    }

    /// The catalog by name, narrowed by the search and the category.
    public var rows: [Row] { entries.filter(matches).map(row) }

    public func row(_ id: String) -> Row? {
        client.catalog?.extensions.first { $0.id == id }.map(row)
    }

    public var hasCatalog: Bool { client.catalog != nil }

    /// The categories the catalog uses, in their usual order.
    public var categories: [ExtensionCategory] {
        let used = Set((client.catalog?.extensions ?? []).flatMap(\.categories))
        return ExtensionCategory.allCases.filter(used.contains)
    }

    public func categoryName(_ category: ExtensionCategory) -> String {
        L10n.string("extensions.store.category.\(category.rawValue)", language)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Name and description in every language the catalog gives, ignoring case and accents ("cevir" finds "Çevir").
    private func matches(_ entry: StoreEntry) -> Bool {
        if let category, !entry.categories.contains(category) { return false }
        let query = Self.folded(trimmedQuery)
        guard !query.isEmpty else { return true }
        return (Array(entry.name.values) + Array(entry.description.values)).contains { Self.folded($0).contains(query) }
    }

    /// Lowercase without accents, the Turkish dotless ı as i, so a search never depends on the keyboard's language.
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).replacingOccurrences(of: "ı", with: "i")
    }

    /// Why the list is empty: the search, the category, or a catalog with nothing in it. Nil while there are rows.
    public var emptyMessage: String? {
        guard client.catalog != nil, rows.isEmpty else { return nil }
        if !trimmedQuery.isEmpty { return string("extensions.store.empty.search", trimmedQuery) }
        if category != nil { return string("extensions.store.empty.category") }
        return string("extensions.store.empty.catalog")
    }

    private func row(_ entry: StoreEntry) -> Row {
        let status = client.status(of: entry)
        let fromVersion: String? = if case .updateAvailable(let from) = status { from } else { nil }
        return Row(id: entry.id, name: entry.localizedName(language), description: entry.localizedDescription(language), author: entry.author,
                   version: entry.version, fromVersion: fromVersion, icon: Self.icon(entry), permissionSummary: summary(entry),
                   hosts: entry.networkHosts, status: status, statusLabel: label(status), isSelectable: status == .notInstalled,
                   isSelected: status == .notInstalled && selection.contains(entry.id), isInstalling: installing.contains(entry.id),
                   failure: failures[entry.id].map(message))
    }

    private static func icon(_ entry: StoreEntry) -> String {
        entry.icon.hasPrefix("sf:") ? entry.icon : "sf:puzzlepiece.extension"
    }

    private func label(_ status: EntryStatus) -> String? {
        switch status {
        case .notInstalled: nil
        case .installed: string("extensions.store.status.installed")
        case .updateAvailable: string("extensions.store.status.update")
        case .incompatible: string("extensions.store.status.incompatible")
        case .builtIn: string("extensions.source.builtIn")
        }
    }

    /// What it may do, in a few words: "Network: 3 sites · Runs: yt-dlp, ffmpeg, deno".
    private func summary(_ entry: StoreEntry) -> String {
        var parts: [String] = []
        if entry.permissions.contains("network") {
            let network = switch entry.networkHosts.count {
            case 0: string("extensions.store.summary.network.any")
            case 1: string("extensions.store.summary.network.site", entry.networkHosts[0])
            default: string("extensions.store.summary.network.sites", "\(entry.networkHosts.count)")
            }
            parts.append(network)
        }
        if entry.permissions.contains("exec") {
            parts.append(entry.tools.isEmpty ? string("extensions.store.summary.exec.any")
                : string("extensions.store.summary.exec", entry.tools.joined(separator: ", ")))
        }
        if entry.permissions.contains("capture") { parts.append(string("extensions.store.summary.capture")) }
        if entry.permissions.contains("history") { parts.append(string("extensions.store.summary.history")) }
        return parts.joined(separator: " · ")
    }

    /// Why an install failed, as its row says it.
    func message(_ failure: InstallFailure) -> String {
        switch failure {
        case .changedSinceShown: string("extensions.store.failed.changed")
        case .store(.offline): string("extensions.store.failed.offline")
        case .store(.badSignature), .store(.malformedCatalog): string("extensions.store.failed.unverified")
        case .store(.badPackage): string("extensions.store.failed.package")
        case .store(.incompatible), .store(.needsNewerApp): string("extensions.store.failed.incompatible")
        case .store(.registry(let reason)): string("extensions.store.failed.registry", reason)
        }
    }

    // MARK: States

    /// The catalog on screen is not the latest: the store could not be reached or could not be trusted.
    public var notice: Notice? {
        guard client.catalog != nil, case .failed(let failure) = client.lastRefresh else { return nil }
        return switch failure {
        case .offline: Notice(symbol: "wifi.slash", text: string("extensions.store.offline.cached"))
        case .needsNewerApp: Notice(symbol: "arrow.up.circle", text: string("extensions.store.newerApp.cached"))
        case .malformedCatalog: Notice(symbol: "doc.questionmark", text: string("extensions.store.malformed.cached"))
        default: Notice(symbol: "exclamationmark.shield", text: string("extensions.store.badSignature.cached"))
        }
    }

    /// No catalog and the refresh failed.
    public var unavailable: Unavailable? {
        guard client.catalog == nil, case .failed(let failure) = client.lastRefresh else { return nil }
        return switch failure {
        case .offline: Unavailable(symbol: "wifi.slash", title: string("extensions.store.offline.title"),
                                   message: string("extensions.store.offline.message"))
        case .needsNewerApp: Unavailable(symbol: "arrow.up.circle", title: string("extensions.store.newerApp.title"),
                                         message: string("extensions.store.newerApp.message"))
        case .malformedCatalog: Unavailable(symbol: "doc.questionmark", title: string("extensions.store.malformed.title"),
                                            message: string("extensions.store.malformed.message"))
        default: Unavailable(symbol: "exclamationmark.shield", title: string("extensions.store.badSignature.title"),
                             message: string("extensions.store.badSignature.message"))
        }
    }

    /// No catalog yet, and none has failed: the first refresh is on its way.
    public var isLoading: Bool { client.catalog == nil && unavailable == nil }

    // MARK: Selecting

    public func setSelected(_ id: String, _ on: Bool) {
        guard row(id)?.isSelectable == true else { return }
        if on { selection.insert(id) } else { selection.remove(id) }
    }

    /// Drops picks that can no longer be installed (gone from the catalog, installed, or now needing a newer
    /// yabbistir), so they never come back ticked on their own.
    private func pruneSelection() {
        let selectable = (client.catalog?.extensions ?? []).filter { client.status(of: $0) == .notInstalled }.map(\.id)
        let kept = selection.intersection(selectable)
        if kept != selection { selection = kept }
    }

    private var selectedEntries: [StoreEntry] {
        entries.filter { selection.contains($0.id) && client.status(of: $0) == .notInstalled }
    }

    public var selectedCount: Int { selectedEntries.count }

    /// "Install (2)", or "Install" with nothing picked.
    public var installTitle: String {
        selectedCount == 0 ? string("extensions.store.install") : string("extensions.store.install.count", "\(selectedCount)")
    }

    public var isInstalling: Bool { installTask != nil }

    // MARK: Updates

    /// Updates this app can run; one that needs a newer yabbistir is left out.
    public var updateCount: Int { client.updates.count }

    /// "2 updates".
    public var updatesTitle: String {
        updateCount == 1 ? string("extensions.store.updates.one") : string("extensions.store.updates.many", "\(updateCount)")
    }

    // MARK: Installing

    /// Install (N): asks once for everything picked, before anything is downloaded.
    public func installSelected() {
        guard installTask == nil else { return }
        let items = selectedEntries.map { entry in
            item(entry, fromVersion: nil, sentences: ConsentText.sentences(permissions: entry.permissions, domains: entry.networkHosts,
                                                                           tools: entry.tools, language: language))
        }
        guard !items.isEmpty else { return }
        pendingConsent = Consent(id: UUID(), kind: .install, items: items, quietUpdates: [])
    }

    /// Update All: the updates that ask for something new are shown under "New permissions" first; when none does,
    /// they are installed straight away.
    public func updateAll() {
        guard installTask == nil else { return }
        let updates = client.updates
        let names = Set(updates.map(\.id))
        var asking: [Consent.Item] = [], quiet: [Consent.Item] = []
        for entry in entries where names.contains(entry.id) {
            let fromVersion: String? = if case .updateAvailable(let from) = client.status(of: entry) { from } else { nil }
            if client.newPermissions(for: entry).isEmpty {
                quiet.append(item(entry, fromVersion: fromVersion, sentences: []))
            } else {
                let granted = registry.installed.first { $0.id == entry.id }?.grant ?? .empty
                let added = Self.newSentences(entry, beyond: granted, language: language)
                let sentences = added.isEmpty
                    ? ConsentText.sentences(permissions: entry.permissions, domains: entry.networkHosts, tools: entry.tools, language: language)
                    : added
                asking.append(item(entry, fromVersion: fromVersion, sentences: sentences))
            }
        }
        guard !asking.isEmpty || !quiet.isEmpty else { return }
        let consent = Consent(id: UUID(), kind: .update, items: asking, quietUpdates: quiet)
        if asking.isEmpty { install(consent) } else { pendingConsent = consent }
    }

    public func confirmConsent() {
        guard let consent = pendingConsent else { return }
        pendingConsent = nil
        install(consent)
    }

    /// Nothing was downloaded, so nothing needs undoing.
    public func cancelConsent() {
        pendingConsent = nil
    }

    private func item(_ entry: StoreEntry, fromVersion: String?, sentences: [String]) -> Consent.Item {
        Consent.Item(id: entry.id, name: entry.localizedName(language), icon: Self.icon(entry), version: entry.version, fromVersion: fromVersion,
                     sentences: sentences, grant: PermissionGrant(permissions: entry.permissions, domains: entry.networkHosts, tools: entry.tools),
                     entry: entry)
    }

    /// Installs one extension at a time; right after each one succeeds, the grant its sheet showed is approved.
    private func install(_ consent: Consent) {
        guard installTask == nil else { return }
        // Items under "New permissions" (or every item of an install) are approved; quiet updates keep their grant.
        let work = consent.items.map { ($0, true) } + consent.quietUpdates.map { ($0, false) }
        guard !work.isEmpty else { return }
        for (item, _) in work { failures[item.id] = nil }
        installing = Set(work.map { item, _ in item.id })
        let client = client, registry = registry
        installTask = Task {
            for (item, approves) in work {
                // Checked right before each download, since a refresh may land while the sheet is open or during the
                // install before this one. The client looks the entry up by id before its first suspension, so what it
                // downloads is the offer compared here.
                guard let current = client.catalog?.extensions.first(where: { $0.id == item.id }), Self.offersTheSame(current, item.entry) else {
                    failures[item.id] = .changedSinceShown
                    installing.remove(item.id)
                    continue
                }
                let outcome: StoreFailure? = await client.install([item.entry])[item.id] ?? .badPackage(id: item.id)
                if let outcome {
                    failures[item.id] = .store(outcome)
                } else {
                    if approves { registry.approve(item.id, grant: item.grant) }
                    selection.remove(item.id)
                }
                installing.remove(item.id)
            }
            pruneSelection()
            installTask = nil
        }
    }

    /// The same download with the same request: version, permissions, sites, programs and package hash.
    private static func offersTheSame(_ current: StoreEntry, _ shown: StoreEntry) -> Bool {
        current.version == shown.version && current.permissions == shown.permissions && current.networkHosts == shown.networkHosts
            && current.tools == shown.tools && current.sha256 == shown.sha256
    }

    /// What `entry` asks for beyond `granted`, one sentence per new kind of access: a site list holds only the new
    /// sites, a program list only the new programs.
    static func newSentences(_ entry: StoreEntry, beyond granted: PermissionGrant, language: AppLanguage) -> [String] {
        let has = Set(granted.permissions)
        var permissions: [String] = [], domains: [String] = [], tools: [String] = []
        if entry.permissions.contains("network") {
            let grantReachesAnyWebsite = has.contains("network") && granted.domains.isEmpty
            if !has.contains("network") {
                permissions.append("network")
                domains = entry.networkHosts
            } else if !grantReachesAnyWebsite {
                if entry.networkHosts.isEmpty {
                    // Any website is more than a list of sites.
                    permissions.append("network")
                } else {
                    let added = entry.networkHosts.filter { !granted.domains.contains($0) }
                    if !added.isEmpty {
                        permissions.append("network")
                        domains = added
                    }
                }
            }
        }
        if entry.permissions.contains("exec") {
            let added = has.contains("exec") ? entry.tools.filter { !granted.tools.contains($0) } : entry.tools
            if !has.contains("exec") || !added.isEmpty {
                permissions.append("exec")
                tools = added
            }
        }
        for permission in ["capture", "history"] where entry.permissions.contains(permission) && !has.contains(permission) {
            permissions.append(permission)
        }
        return ConsentText.sentences(permissions: permissions, domains: domains, tools: tools, language: language)
    }
}
