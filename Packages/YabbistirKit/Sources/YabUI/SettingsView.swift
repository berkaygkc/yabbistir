import SwiftUI
import YabLocalization

/// The Settings sidebar's sections, in the order they are listed.
public enum SettingsSection: String, CaseIterable, Hashable {
    case general, shortcuts, panel, history, categories, extensions, permissions, about

    public var titleKey: String { "settings.section.\(rawValue)" }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .panel: "macwindow"
        case .history: "clock.arrow.circlepath"
        case .categories: "tag"
        case .extensions: "puzzlepiece.extension"
        case .permissions: "hand.raised"
        case .about: "info.circle"
        }
    }
}

/// What the Settings window shows and edits.
public struct SettingsModels {
    public let preferences: Preferences
    public let language: LanguageStore
    public let general: GeneralSettingsModel
    public let history: HistorySettingsModel
    public let extensions: ExtensionsSettingsModel
    public let store: StoreModel

    public init(preferences: Preferences, language: LanguageStore, general: GeneralSettingsModel,
                history: HistorySettingsModel, extensions: ExtensionsSettingsModel, store: StoreModel) {
        self.preferences = preferences
        self.language = language
        self.general = general
        self.history = history
        self.extensions = extensions
        self.store = store
    }
}

/// The Settings window: a sidebar of sections beside the chosen one.
public struct SettingsView: View {
    let models: SettingsModels
    @State private var section: SettingsSection? = .general

    public init(models: SettingsModels) {
        self.models = models
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, id: \.self, selection: $section) { section in
                Label(L10n.string(section.titleKey, models.language.language), systemImage: section.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch section ?? .general {
            case .general:
                GeneralSettingsView(model: models.general)
            case .shortcuts:
                ShortcutsSettingsView(language: models.language)
            case .extensions:
                ExtensionsSettingsView(model: models.extensions, store: models.store)
            case .panel:
                PanelSettingsView(preferences: models.preferences, language: models.language)
            case .history:
                HistorySettingsView(model: models.history, language: models.language)
            case let other:
                SettingsPlaceholder(section: other, language: models.language)
            }
        }
        .environment(\.locale, models.language.language.locale)
    }
}

/// A section that is not built yet: its title, centered.
struct SettingsPlaceholder: View {
    let section: SettingsSection
    let language: LanguageStore

    var body: some View {
        Text(L10n.string(section.titleKey, language.language))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
