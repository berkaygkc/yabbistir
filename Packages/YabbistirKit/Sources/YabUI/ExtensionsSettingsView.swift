import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YabExtensionKit
import YabExtensions
import YabLocalization

/// Settings → Extensions: Installed (the list, with each one's details and preferences), Store (the signed
/// catalog) and Development (install, link, reload, and the log).
public struct ExtensionsSettingsView: View {
    @Bindable var model: ExtensionsSettingsModel
    let store: StoreModel
    @State private var tab: Tab
    @State private var removing: ExtensionsSettingsModel.Row?

    public enum Tab: Hashable, Sendable {
        case installed, store, development
    }

    public init(model: ExtensionsSettingsModel, store: StoreModel, tab: Tab = .installed) {
        self.model = model
        self.store = store
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(string("extensions.tab.installed")).tag(Tab.installed)
                Text(string("extensions.tab.store")).tag(Tab.store)
                Text(string("extensions.tab.development")).tag(Tab.development)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 12)
            Divider()
            switch tab {
            case .installed: installed
            // Only this tab reaches the network, and only once it is shown.
            case .store: StoreView(model: store)
            case .development: development
            }
        }
        .navigationTitle(string("settings.section.extensions"))
    }

    private func string(_ key: String) -> String { L10n.string(key, model.language) }

    // MARK: Installed

    private var installed: some View {
        VStack(spacing: 0) {
            Form {
                Toggle(string("extensions.thirdParty"), isOn: Binding(get: { model.thirdPartyDisabled }, set: { model.thirdPartyDisabled = $0 }))
                    .toggleStyle(.switch)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 76)
            Divider()
            installedBody
        }
    }

    private var installedBody: some View {
        HStack(spacing: 0) {
            List(selection: $model.selectedID) {
                ForEach(model.rows) { row in
                    ExtensionListRow(row: row, waiting: string("extensions.waiting")) { model.setEnabled(row.id, $0) }
                        .tag(row.id)
                }
            }
            .listStyle(.inset)
            .frame(width: 290)
            Divider()
            if let detail = model.selected {
                ExtensionDetailView(detail: detail, model: model) { removing = detail.row }
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if model.selectedID == nil { model.selectedID = model.rows.first?.id } }
        .sheet(item: $model.pendingConsent) { request in
            ExtensionConsentSheet(request: request, language: model.language,
                                  onAllow: { model.approveConsent() }, onDecline: { model.declineConsent() })
        }
        .confirmationDialog(removing.map { L10n.string("extensions.remove.confirm", model.language, $0.name) } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(string("extensions.remove"), role: .destructive) {
                if let removing { model.remove(removing.id) }
            }
        }
    }

    // MARK: Development

    private var development: some View {
        Form {
            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { installButtons }
                    VStack(alignment: .leading, spacing: 8) { installButtons }
                }
                HStack(spacing: 8) {
                    Button(string("extensions.openFolder")) { NSWorkspace.shared.open(model.extensionsFolder) }
                    Button(string("extensions.reload")) { model.reload() }
                }
            }
            if let error = model.lastError {
                Section {
                    Label {
                        Text(error).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
            Section(string("extensions.log")) {
                if model.logs.entries.isEmpty {
                    Text(string("extensions.log.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(model.logs.entries.reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(entry.extensionID.split(separator: ".").last.map(String.init) ?? entry.extensionID)
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var installButtons: some View {
        Button(string("extensions.install.folder")) {
            if let url = Self.choose(directories: true) { model.installFolder(url) }
        }
        Button(string("extensions.install.archive")) {
            if let url = Self.choose(directories: false) { model.installArchive(url) }
        }
        Button(string("extensions.link")) {
            if let url = Self.choose(directories: true) { model.linkFolder(url) }
        }
    }

    private static func choose(directories: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        if !directories { panel.allowedContentTypes = [UTType(filenameExtension: "yabext") ?? .zip, .zip] }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A list row: icon, name, version and source, and the on/off switch.
struct ExtensionListRow: View {
    let row: ExtensionsSettingsModel.Row
    let waiting: String
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ExtensionIconTile(icon: row.icon, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if row.needsConsent {
                    Text(waiting).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    HStack(spacing: 6) {
                        Text(row.version).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        TagChip(text: row.sourceLabel)
                    }
                }
            }
            Spacer(minLength: 6)
            if row.hasProblems {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Toggle("", isOn: Binding(get: { row.isEnabled }, set: onToggle))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!row.canToggle)
        }
        .padding(.vertical, 4)
    }
}

/// One extension: who made it and what it does, its commands, preferences and problems.
struct ExtensionDetailView: View {
    let detail: ExtensionsSettingsModel.Detail
    let model: ExtensionsSettingsModel
    let onRemove: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    ExtensionIconTile(icon: detail.row.icon, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(detail.row.name).font(.system(size: 15, weight: .semibold))
                        Text([detail.row.version, detail.author, detail.row.sourceLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        if !detail.description.isEmpty {
                            Text(detail.description).font(.system(size: 12.5)).padding(.top, 4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if detail.canRemove {
                        Button(L10n.string("extensions.remove", model.language), role: .destructive, action: onRemove)
                    }
                }
                .padding(.vertical, 4)
            }
            if !detail.permissions.isEmpty {
                Section(L10n.string("extensions.permissions", model.language)) {
                    ForEach(detail.permissions, id: \.self) { sentence in
                        Text(sentence)
                            .font(.system(size: 12.5))
                            .foregroundStyle(sentence == unsignedNote ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if detail.needsConsent {
                        HStack(spacing: 10) {
                            Label(L10n.string("extensions.waiting", model.language), systemImage: "lock")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button(L10n.string("extensions.consent.review", model.language)) { model.reviewPermissions(detail.row.id) }
                        }
                    }
                }
            }
            if !detail.missingTools.isEmpty {
                Section {
                    ForEach(detail.missingTools, id: \.name) { tool in missingTool(tool) }
                }
            }
            if !detail.commands.isEmpty {
                Section(L10n.string("extensions.commands", model.language)) {
                    ForEach(detail.commands) { command in
                        LabeledContent(command.title) {
                            ChipFlow(spacing: 4) { ForEach(command.keywords, id: \.self) { TagChip(text: $0) } }
                                .frame(maxWidth: 220, alignment: .trailing)
                        }
                    }
                }
            }
            if !detail.rules.isEmpty {
                Section(L10n.string("extensions.rules", model.language)) {
                    ForEach(detail.rules) { rule in
                        Toggle(isOn: Binding(get: { rule.isEnabled }, set: { model.setRuleEnabled(detail.row.id, rule.id, $0) })) {
                            Text(rule.title)
                            if let description = rule.description { Text(description) }
                        }
                        .toggleStyle(.switch)
                    }
                }
            }
            if !detail.preferences.isEmpty {
                Section(L10n.string("extensions.preferences", model.language)) {
                    ForEach(detail.preferences) { preference in control(for: preference) }
                }
            }
            if !detail.issues.isEmpty {
                Section(L10n.string("extensions.issues", model.language)) {
                    ForEach(detail.issues, id: \.self) { issue in
                        Text(issue).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(model.pendingPreferenceConfirm?.text ?? "",
                            isPresented: Binding(get: { model.pendingPreferenceConfirm != nil },
                                                 // Whether SwiftUI resets this before or after the button runs, the buttons
                                                 // carry their own request; a dismissal cancels on the next turn.
                                                 set: { if !$0 { DispatchQueue.main.async { model.cancelPreference() } } }),
                            presenting: model.pendingPreferenceConfirm) { request in
            Button(L10n.string("extensions.preference.turnOn", model.language)) { model.confirmPreference(request) }
            Button(L10n.string("extensions.cancel", model.language), role: .cancel) { model.cancelPreference() }
        }
    }

    private var unsignedNote: String { L10n.string("permissions.unsigned", model.language) }

    /// "yt-dlp isn't installed", its install command to select, and a Copy button.
    private func missingTool(_ tool: ToolSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.string("extensions.tools.missing", model.language, tool.name), systemImage: "exclamationmark.triangle")
                .font(.system(size: 12.5, weight: .medium))
            HStack(spacing: 10) {
                Text(tool.install)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.string("extensions.tools.copy", model.language)) { model.copy(tool.install) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func control(for preference: ExtensionsSettingsModel.Preference) -> some View {
        let id = detail.row.id
        switch preference.kind {
        case .text:
            TextField(preference.title, text: Binding(get: { preference.value.stringValue ?? "" },
                                                      set: { model.setPreference(id, preference.id, .string($0)) }))
        case .toggle:
            Toggle(preference.title, isOn: Binding(get: { preference.value == .bool(true) },
                                                   set: { model.setPreference(id, preference.id, .bool($0)) }))
        case .secret:
            SecretPreferenceRow(preference: preference, language: model.language) { model.setSecret(id, preference.id, $0) }
        case .folder:
            FolderPreferenceRow(preference: preference, language: model.language) { model.setFolder(id, preference.id, $0) }
        case .choice:
            Picker(preference.title, selection: Binding(get: { preference.value.stringValue ?? "" },
                                                        set: { model.setPreference(id, preference.id, .string($0)) })) {
                ForEach(preference.options) { option in Text(option.title).tag(option.id) }
            }
        }
    }
}

/// A `secret` preference: a field that takes the value and never shows it back. Saved, it reads "Saved"
/// with a way to clear it; the value stays in the Keychain.
struct SecretPreferenceRow: View {
    let preference: ExtensionsSettingsModel.Preference
    let language: AppLanguage
    /// `nil` clears the secret.
    let onSave: (String?) -> Void
    @State private var draft = ""

    var body: some View {
        LabeledContent(preference.title) {
            HStack(spacing: 8) {
                if preference.hasSecret {
                    Text(L10n.string("extensions.secret.saved", language))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(L10n.string("extensions.secret.clear", language)) { onSave(nil) }
                } else {
                    SecureField(preference.title, text: $draft, prompt: Text("••••••••"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .onSubmit(save)
                    Button(L10n.string("extensions.secret.save", language), action: save)
                        .disabled(draft.isEmpty)
                }
            }
        }
    }

    private func save() {
        guard !draft.isEmpty else { return }
        onSave(draft)
        draft = ""
    }
}

/// A `folder` preference: the picked folder in quiet text, "Choose…" (a folder-only open panel) and "Clear". With
/// none picked it reads "No folder chosen", the manifest's default under it as a suggestion, and the open panel
/// starts there; a default grants nothing until it is picked, so it never looks chosen and has nothing to clear.
struct FolderPreferenceRow: View {
    let preference: ExtensionsSettingsModel.Preference
    let language: AppLanguage
    /// The picked folder's path; nil clears it.
    let onChange: (String?) -> Void

    private var path: String? { preference.isChosen ? preference.value.stringValue : nil }

    var body: some View {
        LabeledContent(preference.title) {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L10n.string("extensions.folder.none", language))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .help(path ?? "")
                    if let suggested = preference.suggested {
                        Text(L10n.string("extensions.folder.suggested", language, suggested))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .help(suggested)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .trailing)
                Button(L10n.string("extensions.folder.choose", language), action: choose)
                if path != nil {
                    Button(L10n.string("extensions.folder.clear", language)) { onChange(nil) }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.string("extensions.folder.choose", language)
        if let start = path ?? preference.suggested.map({ ($0 as NSString).expandingTildeInPath }) {
            panel.directoryURL = URL(fileURLWithPath: start)
        }
        if panel.runModal() == .OK, let url = panel.url { onChange(url.path) }
    }
}

/// An extension's icon on a quiet rounded tile.
struct ExtensionIconTile: View {
    let icon: String
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Tokens.Colors.keycapFill)
            .frame(width: size, height: size)
            .overlay {
                CommandIcon(icon: icon).scaleEffect(size / 20 * 0.85)
            }
    }
}

/// The consent sheet: what the extension asks for, and the choice to allow it. ↵ allows, ⎋ declines.
struct ExtensionConsentSheet: View {
    let request: ExtensionsSettingsModel.ConsentRequest
    let language: AppLanguage
    let onAllow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("extensions.consent.title", language, request.name))
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(request.sentences, id: \.self) { sentence in
                    let isNote = sentence == L10n.string("permissions.unsigned", language)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(sentence).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(isNote ? .secondary : .primary)
                }
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L10n.string(request.isNewInstall ? "extensions.consent.decline" : "extensions.cancel", language), action: onDecline)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string(request.isNewInstall ? "extensions.consent.install" : "extensions.consent.allow", language), action: onAllow)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 420)
        .environment(\.locale, language.locale)
        .interactiveDismissDisabled()
    }
}
