import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import YabCore
import YabLocalization

/// Settings → History: how long items are kept (shortening it asks first), the apps nothing is saved from,
/// and what else reaches History.
@MainActor @Observable
public final class HistorySettingsModel {
    public let preferences: Preferences
    @ObservationIgnored private let library: Library
    @ObservationIgnored private let now: () -> Date
    /// A shorter period waiting for the person's say, with how many items it removes right now.
    public private(set) var pendingRetention: RetentionPolicy?
    public private(set) var pendingCount = 0
    /// How much disk space History uses; nil until measured.
    public private(set) var storageBytes: Int64?
    public var confirmingClear = false
    /// Told which items clearing deleted, so the Sıra and result folders can follow.
    @ObservationIgnored public var onCleared: (([Int64]) -> Void)?
    @ObservationIgnored private let storageDirectory: URL?

    public init(preferences: Preferences, library: Library, storageDirectory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.preferences = preferences
        self.library = library
        self.storageDirectory = storageDirectory
        self.now = now
    }

    /// Measures History's size off the main thread.
    public func measureStorage() {
        guard let directory = storageDirectory else { return }
        Task {
            let bytes = await Task.detached(priority: .utility) { HistoryStorage.size(of: directory) }.value
            storageBytes = bytes
        }
    }

    /// Deletes everything in History that is in no category (the person confirmed first).
    public func clearHistory() {
        confirmingClear = false
        guard let deleted = try? library.clearHistory() else { return }
        onCleared?(deleted)
        measureStorage()
    }

    public var ignoredApps: [String] { preferences.ignoredApps }

    /// Applies the period at once, unless it is shorter and would remove items: then it waits for `confirmRetention()`.
    public func requestRetention(_ policy: RetentionPolicy) {
        guard policy != preferences.retention else { return }
        let date = now()
        if Self.isShorter(policy, than: preferences.retention, now: date),
           let count = try? library.countExpired(policy: policy, now: date), count > 0 {
            pendingRetention = policy
            pendingCount = count
            return
        }
        pendingRetention = nil
        preferences.retention = policy
    }

    /// Saves the waiting period and removes what it expires.
    public func confirmRetention() {
        guard let policy = pendingRetention else { return }
        pendingRetention = nil
        preferences.retention = policy
        try? library.purgeExpired(policy: policy, now: now())
    }

    public func cancelRetention() {
        pendingRetention = nil
    }

    public func addIgnoredApp(bundleID: String) {
        guard !bundleID.isEmpty, !preferences.ignoredApps.contains(bundleID) else { return }
        preferences.ignoredApps.append(bundleID)
    }

    public func removeIgnoredApp(bundleID: String) {
        preferences.ignoredApps.removeAll { $0 == bundleID }
    }

    private static func isShorter(_ policy: RetentionPolicy, than other: RetentionPolicy, now: Date) -> Bool {
        guard let cutoff = policy.cutoff(now: now) else { return false }
        guard let otherCutoff = other.cutoff(now: now) else { return true }
        return cutoff > otherCutoff
    }
}

public struct HistorySettingsView: View {
    @Bindable var model: HistorySettingsModel
    let language: LanguageStore
    @State private var selection: String?

    public init(model: HistorySettingsModel, language: LanguageStore) {
        self.model = model
        self.language = language
    }

    private var lang: AppLanguage { language.language }

    public var body: some View {
        @Bindable var preferences = model.preferences
        return Form {
            Section {
                Picker(string("settings.history.retention"), selection: Binding(
                    get: { preferences.retention }, set: { model.requestRetention($0) })) {
                    ForEach(RetentionPolicy.allCases, id: \.self) { Text(string("settings.history.retention.\($0.rawValue)")).tag($0) }
                }
                note("settings.history.retention.note")
            }
            Section {
                List(selection: $selection) {
                    ForEach(model.ignoredApps, id: \.self) { AppRow(bundleID: $0).tag($0) }
                }
                .frame(minHeight: 96)
                HStack(spacing: 4) {
                    Button { chooseApps() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                }
                .buttonStyle(.borderless)
            } header: {
                Text(string("settings.history.ignored"))
            } footer: {
                note("settings.history.ignored.note")
            }
            Section {
                Toggle(string("settings.history.remote"), isOn: $preferences.keepsRemoteCopies).toggleStyle(.switch)
            }
            Section {
                Toggle(string("settings.history.outputs"), isOn: $preferences.showsExtensionOutputs).toggleStyle(.switch)
                note("settings.history.outputs.note")
            }
            Section {
                if let bytes = model.storageBytes {
                    Text(string("settings.history.storage.size", Self.formatted(bytes, lang))).monospacedDigit()
                }
                Button(string("settings.history.clear")) { model.confirmingClear = true }
            } header: {
                Text(string("settings.history.storage"))
            }
        }
        .formStyle(.grouped)
        .onAppear { model.measureStorage() }
        .navigationTitle(string("settings.section.history"))
        .confirmationDialog(
            string("settings.history.retention.confirm", model.pendingCount),
            isPresented: Binding(get: { model.pendingRetention != nil }, set: { if !$0 { model.cancelRetention() } }),
            titleVisibility: .visible
        ) {
            Button(string("settings.history.retention.apply"), role: .destructive) { model.confirmRetention() }
            Button(string("settings.cancel"), role: .cancel) { model.cancelRetention() }
        }
        .confirmationDialog(
            string("settings.history.clear.title"), isPresented: $model.confirmingClear, titleVisibility: .visible
        ) {
            Button(string("settings.history.clear.confirm"), role: .destructive) { model.clearHistory() }
            Button(string("settings.cancel"), role: .cancel) {}
        } message: {
            Text(string("settings.history.clear.message"))
        }
    }

    /// File-style size in the in-app language (not the system's).
    private static func formatted(_ bytes: Int64, _ language: AppLanguage) -> String {
        bytes.formatted(.byteCount(style: .file).locale(language.locale))
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { model.addIgnoredApp(bundleID: id) }
        }
    }

    private func removeSelected() {
        guard let selection else { return }
        model.removeIgnoredApp(bundleID: selection)
        self.selection = nil
    }

    private func string(_ key: String, _ arguments: CVarArg...) -> String {
        arguments.isEmpty ? L10n.string(key, lang) : L10n.string(key, lang, arguments[0])
    }

    private func note(_ key: String) -> some View {
        Text(string(key)).font(.callout).foregroundStyle(.secondary)
    }
}

/// An ignored app: its icon and name, or the bundle identifier when the app is not installed.
private struct AppRow: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundStyle(.secondary)
                Text(bundleID)
            }
        }
    }
}
