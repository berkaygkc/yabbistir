import Foundation
import YabExtensionKit

/// Per-extension choices: on/off, preference values (defaults come from the manifest) and capture rule switches.
public final class ExtensionSettings: @unchecked Sendable {
    private let defaults: UserDefaults
    private let secrets: any SecretStoring

    public init(defaults: UserDefaults = UserDefaults(suiteName: "dev.yabbistir.extensions") ?? .standard,
                secrets: any SecretStoring = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// How much the `Outputs/` folder may hold before the oldest uncategorized results go
    /// (`defaults write dev.yabbistir.extensions outputsLimitBytes -int <n>` lowers it for a check).
    public var outputsLimitBytes: Int64 {
        let stored = defaults.object(forKey: "outputsLimitBytes") as? NSNumber
        return stored?.int64Value ?? 5 * 1024 * 1024 * 1024
    }

    public func isEnabled(_ id: String) -> Bool {
        defaults.object(forKey: "enabled.\(id)") as? Bool ?? true
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        defaults.set(on, forKey: "enabled.\(id)")
    }

    /// What `ctx.preferences` holds: toggles, text, choices and folders. A secret is never here (it
    /// reaches its extension through `secrets`). A folder is the one the person picked (`setFolder`), else the
    /// manifest's default; it reads as an absolute path, `~` expanded in either.
    ///
    /// Values are read by what their key is now: a value stored for a key an update has made a secret (a text
    /// before) is deleted from UserDefaults here and never handed out, and one stored for a key an update has
    /// made a folder is never taken for a picked folder.
    public func preferences(_ id: String, specs: [PreferenceSpec]) -> [String: JSONValue] {
        let stored = storedPreferences(id, specs: specs)
        let folders = pickedFolders(id)
        // The first spec with an id wins (validation reports duplicates; reading them never traps).
        return Dictionary(specs.filter { $0.type != .secret }.map { spec in
            guard spec.type == .folder else { return (spec.id, stored[spec.id] ?? spec.default) }
            let value = folders[spec.id].map(JSONValue.string) ?? spec.default
            if case .string(let path) = value { return (spec.id, JSONValue.string(Self.expandingTilde(path))) }
            return (spec.id, value)
        }) { first, _ in first }
    }

    /// Stores a preference. A secret's key is refused (returns false): its value goes to the Keychain through
    /// `setSecret` and never to UserDefaults. A folder's is refused too: only the folder picker chooses one
    /// (`setFolder`). A key no spec declares is refused too.
    @discardableResult
    public func setPreference(_ id: String, _ key: String, _ value: JSONValue, specs: [PreferenceSpec]) -> Bool {
        guard let spec = specs.first(where: { $0.id == key }), spec.type != .secret, spec.type != .folder else { return false }
        var stored = storedPreferences(id, specs: specs)
        stored[key] = value
        defaults.set(try? JSONEncoder().encode(stored), forKey: "preferences.\(id)")
        return true
    }

    // MARK: Folders

    /// The folder the person picked for a `folder` preference in Settings' folder picker, which alone calls this;
    /// `nil` or an empty path clears it (the manifest's default is back in `ctx.preferences`, granting nothing).
    /// Refused (false) for a key that is not a folder preference. Picked folders are kept apart from every other
    /// value, so nothing typed anywhere ever becomes one.
    @discardableResult
    public func setFolder(_ id: String, _ key: String, _ path: String?, specs: [PreferenceSpec]) -> Bool {
        guard specs.first(where: { $0.id == key })?.type == .folder else { return false }
        var folders = pickedFolders(id)
        folders[key] = path?.isEmpty == false ? path : nil
        defaults.set(folders.isEmpty ? nil : folders, forKey: "folders.\(id)")
        return true
    }

    /// The folder the person picked for one preference, `~` expanded; nil when none is.
    public func chosenFolder(_ id: String, _ key: String) -> String? {
        pickedFolders(id)[key].flatMap { $0.isEmpty ? nil : Self.expandingTilde($0) }
    }

    // MARK: Secrets

    public func hasSecret(_ id: String, _ key: String) -> Bool {
        secrets.read(id, key) != nil
    }

    /// `nil` or an empty value clears it.
    public func setSecret(_ value: String?, _ id: String, _ key: String) throws {
        try secrets.write(value?.isEmpty == true ? nil : value, id, key)
    }

    /// What the manifest's `secret` preferences hold, by key; only keys that are declared and have a value.
    /// It goes to the extension's own load request and nowhere else.
    public func secrets(_ id: String, specs: [PreferenceSpec]) -> [String: String] {
        var found: [String: String] = [:]
        for spec in specs where spec.type == .secret {
            if let value = secrets.read(id, spec.id) { found[spec.id] = value }
        }
        return found
    }

    /// The folders the person picked for `folder` preferences (`setFolder`) and nothing else: what `yab.files` may
    /// read. A manifest default fills `ctx.preferences` but never grants read access.
    public func chosenFolders(_ id: String, specs: [PreferenceSpec]) -> [String] {
        specs.filter { $0.type == .folder }.compactMap { chosenFolder(id, $0.id) }
    }

    static func expandingTilde(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? NSHomeDirectory() + path.dropFirst() : path
    }

    // MARK: Capture rules

    /// Whether one of an extension's capture rules runs on new copies; on unless the person turned it off.
    public func isRuleEnabled(_ id: String, _ rule: String) -> Bool {
        ruleSwitches(id)[rule] ?? true
    }

    public func setRuleEnabled(_ id: String, _ rule: String, _ on: Bool) {
        var switches = ruleSwitches(id)
        switches[rule] = on
        defaults.set(switches, forKey: "rules.\(id)")
    }

    /// One entry per extension, so removing it forgets every rule's switch without knowing their ids.
    private func ruleSwitches(_ id: String) -> [String: Bool] {
        defaults.dictionary(forKey: "rules.\(id)") as? [String: Bool] ?? [:]
    }

    /// The version of an extension whose detectors last scanned the whole history.
    public func scannedDetectorVersion(_ id: String) -> String? {
        defaults.string(forKey: "scanned.\(id)")
    }

    public func setScannedDetectorVersion(_ id: String, _ version: String) {
        defaults.set(version, forKey: "scanned.\(id)")
    }

    /// What the person approved for an extension; nil until they approve.
    public func grant(_ id: String) -> PermissionGrant? {
        defaults.data(forKey: "grant.\(id)").flatMap { try? JSONDecoder().decode(PermissionGrant.self, from: $0) }
    }

    public func setGrant(_ id: String, _ grant: PermissionGrant?) {
        defaults.set(grant.flatMap { try? JSONEncoder().encode($0) }, forKey: "grant.\(id)")
    }

    /// The master switch: on, only built-in extensions are usable.
    public var thirdPartyDisabled: Bool {
        get { defaults.bool(forKey: "thirdPartyDisabled") }
        set { defaults.set(newValue, forKey: "thirdPartyDisabled") }
    }

    /// Forgets everything about an extension (it was removed).
    public func remove(_ id: String, specs: [PreferenceSpec]) {
        for spec in specs where spec.type == .secret { try? secrets.write(nil, id, spec.id) }
        defaults.removeObject(forKey: "enabled.\(id)")
        defaults.removeObject(forKey: "preferences.\(id)")
        defaults.removeObject(forKey: "folders.\(id)")
        defaults.removeObject(forKey: "rules.\(id)")
        defaults.removeObject(forKey: "scanned.\(id)")
        defaults.removeObject(forKey: "grant.\(id)")
    }

    /// The values stored for an extension, less any whose key is a secret now: those are deleted from UserDefaults.
    private func storedPreferences(_ id: String, specs: [PreferenceSpec]) -> [String: JSONValue] {
        let stored = defaults.data(forKey: "preferences.\(id)").flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        let secrets = Set(specs.filter { $0.type == .secret }.map(\.id))
        guard stored.keys.contains(where: secrets.contains) else { return stored }
        let kept = stored.filter { !secrets.contains($0.key) }
        defaults.set(kept.isEmpty ? nil : try? JSONEncoder().encode(kept), forKey: "preferences.\(id)")
        return kept
    }

    /// Picked folders by key: one entry per extension (removing it forgets them all), written only by `setFolder`.
    private func pickedFolders(_ id: String) -> [String: String] {
        defaults.dictionary(forKey: "folders.\(id)") as? [String: String] ?? [:]
    }
}
