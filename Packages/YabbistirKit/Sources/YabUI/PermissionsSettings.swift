import AppKit
import Observation
import SwiftUI
import YabLocalization
import YabPlatform

public enum PermissionKind: CaseIterable, Sendable {
    case accessibility, inputMonitoring, pasteboard, loginItem

    var keyPrefix: String {
        switch self {
        case .accessibility: "accessibility"
        case .inputMonitoring: "inputMonitoring"
        case .pasteboard: "pasteboard"
        case .loginItem: "loginItem"
        }
    }
}

public enum PermissionState: Equatable, Sendable {
    case granted, needed, optional

    var statusKey: String {
        switch self {
        case .granted: "settings.permissions.granted"
        case .needed: "settings.permissions.needed"
        case .optional: "settings.permissions.optional"
        }
    }
}

public struct PermissionCard: Identifiable, Equatable, Sendable {
    public let kind: PermissionKind
    public let state: PermissionState
    public let titleKey: String
    public let purposeKey: String
    public let stepsKey: String
    public let statusKey: String

    public var id: PermissionKind { kind }

    init(_ kind: PermissionKind, _ state: PermissionState, statusKey: String? = nil) {
        self.kind = kind
        self.state = state
        titleKey = "settings.permissions.\(kind.keyPrefix).title"
        purposeKey = "settings.permissions.\(kind.keyPrefix).purpose"
        stepsKey = "settings.permissions.\(kind.keyPrefix).steps"
        self.statusKey = statusKey ?? state.statusKey
    }
}

/// Settings → Permissions: the live state of each permission and where to change it.
@MainActor @Observable
public final class PermissionsModel {
    public let languageStore: LanguageStore
    public private(set) var cards: [PermissionCard] = []
    @ObservationIgnored private let probe: PermissionProbing
    @ObservationIgnored private let loginItem: LoginItemControlling
    @ObservationIgnored private let openURL: (URL) -> Bool

    public init(probe: PermissionProbing, loginItem: LoginItemControlling, language: LanguageStore,
                openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.probe = probe
        self.loginItem = loginItem
        self.languageStore = language
        self.openURL = openURL
        refresh()
    }

    public var language: AppLanguage { languageStore.language }

    /// Reads the system again; the person may have changed it in System Settings.
    public func refresh() {
        var next = [
            PermissionCard(.accessibility, probe.accessibility ? .granted : .needed),
            PermissionCard(.inputMonitoring, probe.inputMonitoring ? .granted : .optional),
            pasteboardCard(probe.pasteboard),
        ]
        switch probe.loginItem {
        case .enabled: next.append(PermissionCard(.loginItem, .granted))
        case .requiresApproval: next.append(PermissionCard(.loginItem, .needed))
        case .disabled: next.append(PermissionCard(.loginItem, .optional))
        case .unavailable: break
        }
        if next != cards { cards = next }
    }

    private func pasteboardCard(_ access: PasteboardAccess) -> PermissionCard {
        let prefix = "settings.permissions.\(PermissionKind.pasteboard.keyPrefix)"
        switch access {
        case .notAsked: return PermissionCard(.pasteboard, .granted, statusKey: prefix + ".notAsked")
        case .allowed: return PermissionCard(.pasteboard, .granted)
        case .ask: return PermissionCard(.pasteboard, .needed, statusKey: prefix + ".ask")
        case .denied: return PermissionCard(.pasteboard, .needed, statusKey: prefix + ".denied")
        }
    }

    public func open(_ kind: PermissionKind) {
        switch kind {
        case .accessibility: _ = openURL(SystemSettingsLink.accessibility)
        case .inputMonitoring: _ = openURL(SystemSettingsLink.inputMonitoring)
        case .pasteboard:
            if !openURL(SystemSettingsLink.pasteboard) { _ = openURL(SystemSettingsLink.privacy) }
        case .loginItem: loginItem.openSystemSettings()
        }
    }
}

public struct PermissionsSettingsView: View {
    let model: PermissionsModel

    public init(model: PermissionsModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            ForEach(model.cards) { card in
                Section {
                    LabeledContent {
                        badge(card)
                    } label: {
                        Text(string(card.titleKey)).font(.headline)
                    }
                    note(card.purposeKey)
                    note(card.stepsKey)
                    Button(string("settings.openSystemSettings")) { model.open(card.kind) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(string("settings.section.permissions"))
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.refresh()
            }
        }
    }

    private func badge(_ card: PermissionCard) -> some View {
        Text(string(card.statusKey))
            .font(.callout.weight(.medium))
            .foregroundStyle(color(card.state))
    }

    private func color(_ state: PermissionState) -> Color {
        switch state {
        case .granted: .green
        case .needed: .orange
        case .optional: .secondary
        }
    }

    private func string(_ key: String) -> String { L10n.string(key, model.language) }

    private func note(_ key: String) -> some View {
        Text(string(key)).font(.callout).foregroundStyle(.secondary)
    }
}
