import AppKit
import Foundation
import Observation
import YabExtensionKit
import YabExtensions
import YabLocalization

/// What extensions printed (console.log and errors), the last 200 lines of each, for the
/// Development tab. `ExtensionHostClient`'s log handler writes here.
@MainActor @Observable
public final class ExtensionLogBuffer {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: Int
        public let extensionID: String
        public let message: String
        public let date: Date
    }

    public static let limit = 200
    public private(set) var entries: [Entry] = []
    @ObservationIgnored private var nextID = 0

    public init() {}

    public func append(_ extensionID: String, _ message: String, at date: Date = Date()) {
        entries.append(Entry(id: nextID, extensionID: extensionID, message: message, date: date))
        nextID += 1
        if entries.lazy.filter({ $0.extensionID == extensionID }).count > Self.limit,
           let oldest = entries.firstIndex(where: { $0.extensionID == extensionID }) {
            entries.remove(at: oldest)
        }
    }

    public func lines(for extensionID: String) -> [String] {
        entries.filter { $0.extensionID == extensionID }.map(\.message)
    }
}

/// Settings → Extensions: the installed list with on/off switches, one extension's details and
/// preferences, and the developer's install and link actions.
@MainActor @Observable
public final class ExtensionsSettingsModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let version: String
        public let icon: String
        public let source: ExtensionSource
        /// "Built-in", "Local" or "Development".
        public let sourceLabel: String
        /// Reads as off while the third-party master switch is on (built-ins excepted).
        public let isEnabled: Bool
        public let hasProblems: Bool
        /// It asks for permissions the person has not approved: "Waiting for your permission".
        public let needsConsent: Bool
        /// Its own switch can be used: not while the master switch is on, and not while waiting for consent.
        public let canToggle: Bool
    }

    /// What the consent sheet shows: an extension's permission sentences, and whether declining
    /// removes it (a fresh install or link) or only leaves it waiting (a review).
    public struct ConsentRequest: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var sentences: [String]
        public var isNewInstall: Bool
        /// What the sentences describe: exactly what approving records, even if the manifest asks
        /// for more by then (it then keeps waiting until that is shown too).
        public var grant: PermissionGrant
    }

    /// A preference change held back until the person confirms it.
    public struct PreferenceConfirmation: Equatable, Sendable {
        public var id: String
        public var key: String
        public var value: JSONValue
        public var text: String
    }

    public struct Command: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var keywords: [String]
    }

    /// A capture rule: what it is called, what it does, and whether it runs on new copies.
    public struct Rule: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var description: String?
        public var isEnabled: Bool
    }

    public struct Preference: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var kind: PreferenceSpec.Kind
        /// A secret never carries its value (it is `.null`); `hasSecret` says whether one is stored.
        public var value: JSONValue
        /// A `secret` preference has a value in the Keychain. The value itself is never read back here.
        public var hasSecret = false
        /// A `folder` preference has a folder the person picked, whose path is `value`. Without one `value` is
        /// `.null`: a manifest's default grants nothing, so it never shows as chosen.
        public var isChosen = false
        /// A `folder` preference with none picked: its manifest default, as the row suggests it ("~/Downloads").
        public var suggested: String?
        /// Whether a non-default value is confirmed first.
        public var asksConfirmation = false
        /// A choice's options: (id, title).
        public var options: [Option]

        public struct Option: Identifiable, Equatable, Sendable {
            public var id: String
            public var title: String
        }
    }

    public struct Detail: Equatable, Sendable {
        public var row: Row
        public var description: String
        public var author: String
        public var commands: [Command]
        public var rules: [Rule]
        public var preferences: [Preference]
        /// "path: message (fix)".
        public var issues: [String]
        public var canRemove: Bool
        /// The permission sentences, listed whether or not the extension still needs consent.
        public var permissions: [String]
        public var needsConsent: Bool
        /// Tools the extension needs that are not installed, with their install commands.
        public var missingTools: [ToolSpec]
    }

    public var selectedID: String?
    /// The last install or remove failure, as the person should read it.
    public private(set) var lastError: String?
    /// Preferences live in UserDefaults; bumped on each change so the detail redraws.
    private var preferenceRevision = 0

    /// Set after an install, link or review that needs the person's approval; the sheet reads it.
    public var pendingConsent: ConsentRequest?
    /// Set when a preference with a `confirm` question is about to leave its default.
    public var pendingPreferenceConfirm: PreferenceConfirmation?
    /// Told the change count of the app's own pasteboard writes, so history does not record them.
    @ObservationIgnored public var onPasteboardWrite: ((Int) -> Void)?

    @ObservationIgnored public let registry: ExtensionRegistry
    @ObservationIgnored public let logs: ExtensionLogBuffer
    @ObservationIgnored private let settings: ExtensionSettings
    @ObservationIgnored private let languageStore: LanguageStore
    @ObservationIgnored private let toolLocator: ToolLocator

    public init(registry: ExtensionRegistry, settings: ExtensionSettings, language: LanguageStore, logs: ExtensionLogBuffer,
                toolLocator: ToolLocator = .standard) {
        self.toolLocator = toolLocator
        self.registry = registry
        self.settings = settings
        self.languageStore = language
        self.logs = logs
    }

    public var language: AppLanguage { languageStore.language }

    /// Built-ins first, then the person's own, each by name (the registry's order).
    public var rows: [Row] { registry.installed.map(row) }

    public var selected: Detail? { selectedID.flatMap(detail) }

    public func detail(for id: String) -> Detail? {
        _ = preferenceRevision
        guard let entry = registry.installed.first(where: { $0.id == id }) else { return nil }
        let code = language.rawValue
        let manifest = entry.manifest, localization = entry.localization
        func text(_ key: String) -> String { localization?.string(key, language: code) ?? key }
        var commands: [Command] = []
        for action in manifest?.contributes.actions ?? [] {
            let keywords = localization?.keywords(action.keywords, language: code) ?? []
            if action.variants.isEmpty {
                commands.append(Command(id: action.id, title: text(action.title), keywords: keywords))
            } else {
                commands += action.variants.map { Command(id: "\(action.id)#\($0.id)", title: text($0.title), keywords: keywords) }
            }
        }
        let rules = (manifest?.contributes.captureRules ?? []).map { rule in
            Rule(id: rule.id, title: text(rule.title), description: rule.description.map(text), isEnabled: settings.isRuleEnabled(id, rule.id))
        }
        let specs = manifest?.preferences ?? []
        let values = settings.preferences(id, specs: specs)
        let preferences = specs.map { spec in
            var preference = Preference(id: spec.id, title: text(spec.title), kind: spec.type,
                                        value: spec.type == .secret ? .null : values[spec.id] ?? spec.default,
                                        hasSecret: spec.type == .secret && settings.hasSecret(id, spec.id),
                                        asksConfirmation: spec.confirm != nil && spec.type != .text && spec.type != .folder,
                                        options: spec.options.map { Preference.Option(id: $0.id, title: text($0.title)) })
            if spec.type == .folder {
                let chosen = settings.chosenFolder(id, spec.id)
                preference.isChosen = chosen != nil
                preference.value = chosen.map(JSONValue.string) ?? .null
                preference.suggested = chosen == nil ? spec.default.stringValue.flatMap(Self.suggestion) : nil
            }
            return preference
        }
        return Detail(row: row(entry), description: manifest.map { text($0.description) } ?? "", author: manifest?.author ?? "",
                      commands: commands, rules: rules, preferences: preferences, issues: entry.issues.map(\.description),
                      canRemove: entry.source != .builtIn, permissions: sentences(for: entry), needsConsent: entry.needsConsent,
                      missingTools: toolLocator.missing(manifest?.requires?.tools ?? []))
    }

    /// A folder default as a person reads it: under the home folder with "~" ("~/Downloads"), nil when empty.
    private static func suggestion(_ path: String) -> String? {
        path.isEmpty ? nil : ((path as NSString).expandingTildeInPath as NSString).abbreviatingWithTildeInPath
    }

    private func sentences(for entry: InstalledExtension) -> [String] {
        guard let manifest = entry.manifest, !PermissionGrant.requested(by: manifest).isEmpty else { return [] }
        return ConsentText.sentences(for: manifest, source: entry.source, language: language)
    }

    // MARK: Installing

    public func installFolder(_ folder: URL) {
        attempt { () throws(RegistryError) in selectedID = try registry.install(folder: folder) }
        askConsentForSelection()
    }

    public func installArchive(_ archive: URL) {
        attempt { () throws(RegistryError) in selectedID = try registry.install(archive: archive) }
        askConsentForSelection()
    }

    public func linkFolder(_ folder: URL) {
        attempt { () throws(RegistryError) in selectedID = try registry.linkDevelopmentFolder(folder) }
        askConsentForSelection()
    }

    // MARK: Consent

    /// After an install or link: an extension that asks for something not yet approved opens the sheet.
    private func askConsentForSelection() {
        guard lastError == nil, let id = selectedID else { return }
        ask(id, isNewInstall: true)
    }

    private func ask(_ id: String, isNewInstall: Bool) {
        guard let entry = registry.installed.first(where: { $0.id == id }), entry.needsConsent, let manifest = entry.manifest else { return }
        pendingConsent = ConsentRequest(id: id, name: entry.name(language: language.rawValue), sentences: sentences(for: entry),
                                        isNewInstall: isNewInstall, grant: PermissionGrant.requested(by: manifest))
    }

    /// "Review Permissions…" in an extension's details.
    public func reviewPermissions(_ id: String) {
        ask(id, isNewInstall: false)
    }

    public func approveConsent() {
        guard let request = pendingConsent else { return }
        pendingConsent = nil
        // What the sheet showed, not what the manifest asks for now.
        registry.approve(request.id, grant: request.grant)
        preferenceRevision += 1
    }

    /// A new install is taken back out (the copy, or the link); an existing extension stays waiting.
    public func declineConsent() {
        guard let request = pendingConsent else { return }
        pendingConsent = nil
        if request.isNewInstall { remove(request.id) }
    }

    // MARK: Copying

    /// Puts text on the general pasteboard; the app is told so its history skips this write.
    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onPasteboardWrite?(NSPasteboard.general.changeCount)
    }

    // MARK: Third-party master switch

    /// Turns off every extension that is not built in. The registry reads it while scanning, so it
    /// is reloaded here.
    public var thirdPartyDisabled: Bool {
        get { _ = preferenceRevision; return settings.thirdPartyDisabled }
        set {
            settings.thirdPartyDisabled = newValue
            registry.reload()
            preferenceRevision += 1
        }
    }

    // MARK: Managing

    public func remove(_ id: String) {
        attempt { () throws(RegistryError) in
            try registry.uninstall(id)
            if selectedID == id { selectedID = nil }
        }
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        registry.setEnabled(id, on)
    }

    /// Turns one capture rule on or off; the next copy already goes by it.
    public func setRuleEnabled(_ id: String, _ rule: String, _ on: Bool) {
        settings.setRuleEnabled(id, rule, on)
        preferenceRevision += 1
    }

    /// Saves a preference. One with a `confirm` question asks first when it leaves its default.
    public func setPreference(_ id: String, _ key: String, _ value: JSONValue) {
        if let entry = registry.installed.first(where: { $0.id == id }),
           let spec = entry.manifest?.preferences.first(where: { $0.id == key }),
           let confirm = spec.confirm, spec.type != .text, spec.type != .folder, spec.type != .secret, value != spec.default {
            let text = entry.localization?.string(confirm, language: language.rawValue) ?? confirm
            pendingPreferenceConfirm = PreferenceConfirmation(id: id, key: key, value: value, text: text)
            preferenceRevision += 1
            return
        }
        pendingPreferenceConfirm = nil
        save(id, key, value)
    }

    /// Saves the confirmed change. It takes the request itself, so the outcome does not depend on
    /// whether the dialog already cleared the pending state.
    public func confirmPreference(_ request: PreferenceConfirmation) {
        pendingPreferenceConfirm = nil
        save(request.id, request.key, request.value)
    }

    public func cancelPreference() {
        pendingPreferenceConfirm = nil
        preferenceRevision += 1
    }

    /// The folder picker's choice for a `folder` preference (only the picker calls this); `nil` clears it.
    public func setFolder(_ id: String, _ key: String, _ path: String?) {
        let specs = registry.installed.first { $0.id == id }?.manifest?.preferences ?? []
        settings.setFolder(id, key, path, specs: specs)
        preferenceRevision += 1
    }

    private func save(_ id: String, _ key: String, _ value: JSONValue) {
        let specs = registry.installed.first { $0.id == id }?.manifest?.preferences ?? []
        settings.setPreference(id, key, value, specs: specs)
        preferenceRevision += 1
    }

    /// Stores a secret in the Keychain (an empty value clears it). The extension is loaded again, so the helper
    /// gets the new load request: the registry's change path, which reloads every extension.
    public func setSecret(_ id: String, _ key: String, _ value: String?) {
        guard registry.installed.first(where: { $0.id == id })?.manifest?.preferences.contains(where: { $0.id == key && $0.type == .secret }) == true else { return }
        do {
            try settings.setSecret(value, id, key)
            lastError = nil
        } catch {
            lastError = L10n.string("extensions.secret.failed", language)
        }
        preferenceRevision += 1
        registry.reload()
    }

    public func reload() {
        lastError = nil
        registry.reload()
    }

    public var extensionsFolder: URL { registry.userRoot }

    // MARK: Helpers

    private func attempt(_ work: () throws(RegistryError) -> Void) {
        do throws(RegistryError) {
            try work()
            lastError = nil
        } catch {
            lastError = error.message
        }
    }

    private func row(_ entry: InstalledExtension) -> Row {
        let locked = entry.source != .builtIn && entry.thirdPartyDisabled
        return Row(id: entry.id, name: entry.name(language: language.rawValue), version: entry.manifest?.version ?? "", icon: entry.manifest?.icon ?? "",
            source: entry.source, sourceLabel: L10n.string("extensions.source.\(entry.source.rawValue)", language),
            isEnabled: entry.isEnabled && !locked, hasProblems: !entry.issues.isEmpty, needsConsent: entry.needsConsent,
            canToggle: !locked && !entry.needsConsent)
    }
}
