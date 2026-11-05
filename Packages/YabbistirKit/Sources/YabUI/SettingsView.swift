import SwiftUI
import YabLocalization

/// The Settings sidebar's sections, in the order they are listed.
public enum SettingsSection: String, CaseIterable, Hashable {
    case general, shortcuts, panel, history, categories, extensions, permissions, `import`, about

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
        case .import: "square.and.arrow.down"
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
    public let categories: CategoryEditorModel
    public let extensions: ExtensionsSettingsModel
    public let store: StoreModel
    public let permissions: PermissionsModel
    public let importer: ImportModel
    public let about: AboutModel
    public let presence: SettingsPresence
    public let navigation: SettingsNavigation

    public init(preferences: Preferences, language: LanguageStore, general: GeneralSettingsModel,
                history: HistorySettingsModel, categories: CategoryEditorModel, extensions: ExtensionsSettingsModel, store: StoreModel,
                permissions: PermissionsModel, importer: ImportModel, about: AboutModel, presence: SettingsPresence,
                navigation: SettingsNavigation) {
        self.preferences = preferences
        self.language = language
        self.general = general
        self.history = history
        self.categories = categories
        self.extensions = extensions
        self.store = store
        self.permissions = permissions
        self.importer = importer
        self.about = about
        self.presence = presence
        self.navigation = navigation
    }
}

/// The Settings window: a sidebar of sections beside the chosen one.
public struct SettingsView: View {
    let models: SettingsModels

    public init(models: SettingsModels) {
        self.models = models
    }

    public var body: some View {
        @Bindable var navigation = models.navigation
        NavigationSplitView {
            List(SettingsSection.allCases, id: \.self, selection: $navigation.section) { section in
                Label(L10n.string(section.titleKey, models.language.language), systemImage: section.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch navigation.section ?? .general {
            case .general:
                GeneralSettingsView(model: models.general, presence: models.presence)
            case .shortcuts:
                ShortcutsSettingsView(language: models.language)
            case .extensions:
                ExtensionsSettingsView(model: models.extensions, store: models.store, tab: $navigation.extensionsTab)
            case .panel:
                PanelSettingsView(preferences: models.preferences, language: models.language)
            case .history:
                HistorySettingsView(model: models.history, language: models.language, presence: models.presence)
            case .categories:
                CategoriesSettingsView(model: models.categories, presence: models.presence)
            case .permissions:
                PermissionsSettingsView(model: models.permissions, presence: models.presence)
            case .import:
                ImportSettingsView(model: models.importer, presence: models.presence)
            case .about:
                AboutSettingsView(model: models.about)
            }
        }
        .environment(\.locale, models.language.language.locale)
    }
}
