import AppKit
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

    /// The sidebar's first width: 200 pt, or wide enough for the language's longest title (German "Tastaturkurzbefehle",
    /// Japanese "キーボードショートカット"), up to the column's 260 pt.
    ///
    /// Titles are measured in the sidebar's own font, which follows System Settings › Appearance › Sidebar icon size:
    /// 11, 13 or 15 pt for small, medium and large rows. Beside its title a row then keeps 84, 88 or 90 pt. Of those,
    /// 59, 63 and 65 pt are the row's own, measured on macOS 26 in a sidebar `List` as wide as the column: the cell's
    /// 16 pt insets and the icon with its gap. The other 25 pt are headroom, so the longest title never ends right at
    /// the inset.
    ///
    /// The limit: these are macOS 26's figures, read from neither AppKit nor SwiftUI, which don't publish them. A later
    /// macOS that pads its sidebar rows by more than the headroom would truncate the longest title until the user drags
    /// the column wider (it goes to 260 pt).
    public static func sidebarWidth(_ language: AppLanguage, rowSize: SidebarRowSize = .medium) -> CGFloat {
        let (fontSize, chrome): (CGFloat, CGFloat) = switch rowSize {
        case .small: (11, 84)
        case .large: (15, 90)
        default: (13, 88)
        }
        let font = NSFont.systemFont(ofSize: fontSize)
        let widest = allCases.map { NSAttributedString(string: L10n.string($0.titleKey, language), attributes: [.font: font]).size().width }
        return min(260, max(200, ceil(widest.max() ?? 0) + chrome))
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
    /// The system's sidebar icon size, which sets the rows' font.
    @Environment(\.sidebarRowSize) private var sidebarRowSize

    public init(models: SettingsModels) {
        self.models = models
    }

    public var body: some View {
        @Bindable var navigation = models.navigation
        NavigationSplitView {
            List(SettingsSection.allCases, id: \.self, selection: $navigation.section) { section in
                Label(L10n.string(section.titleKey, models.language.language), systemImage: section.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: SettingsSection.sidebarWidth(models.language.language, rowSize: sidebarRowSize),
                                           max: 260)
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
