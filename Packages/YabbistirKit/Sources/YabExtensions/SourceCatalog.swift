import Foundation
import YabExtensionKit

/// One of a source's row actions, in the app's language.
public struct SourceActionDescriptor: Equatable, Sendable {
    public var id: String
    public var kind: SourceActionSpec.Kind
    /// What the action does to a row ("Şifreyi yapıştır"): the ↵/⇧↵ rows, ⌘K and the bar's primary.
    public var title: String
    /// The value's short name ("Şifre"): the bar's secondary and the preview line.
    public var label: String
    /// The copy row's title ("Kullanıcı adını kopyala"); text actions only.
    public var copyTitle: String?
    /// The notice after copying ("Kullanıcı adı kopyalandı."); text actions only.
    public var copied: String?

    public init(id: String, kind: SourceActionSpec.Kind, title: String, label: String, copyTitle: String? = nil, copied: String? = nil) {
        (self.id, self.kind, self.title, self.label, self.copyTitle, self.copied) = (id, kind, title, label, copyTitle, copied)
    }
}

/// A list an extension offers as a category column, in the app's language: its name and its rows' actions. The rows
/// themselves are not here: the extension gives them when the panel opens, and only the app's memory keeps them
/// (`SourceCenter`).
public struct SourceDescriptor: Equatable, Sendable, Identifiable {
    /// "<extension id>/<source id>": the column's key, also its category's.
    public var id: String
    public var extensionID: String
    public var extensionName: String
    public var sourceID: String
    /// The column's name.
    public var title: String
    /// Its rows and values are secrets.
    public var sensitive: Bool
    /// One or two, never none, in order: ↵ runs the first, ⇧↵ the second.
    public var actions: [SourceActionDescriptor]

    public init(extensionID: String, extensionName: String, sourceID: String, title: String, sensitive: Bool, actions: [SourceActionDescriptor]) {
        id = "\(extensionID)/\(sourceID)"
        (self.extensionID, self.extensionName, self.sourceID, self.title, self.sensitive, self.actions) =
            (extensionID, extensionName, sourceID, title, sensitive, actions)
    }

    /// ↵.
    public var primary: SourceActionDescriptor { actions[0] }

    /// ⇧↵; nil when the source has one action.
    public var alternate: SourceActionDescriptor? { actions.count > 1 ? actions[1] : nil }

    /// ⌘C: the first text action that can be copied. A secret is never copied.
    public var copyAction: SourceActionDescriptor? { actions.first { $0.kind == .text && $0.copyTitle != nil } }

    /// What the first secret action gives ("Şifre"), for the line that says it is never shown; nil without one.
    public var secretLabel: String? { actions.first { $0.kind == .secret }?.label }
}

/// The sources of the usable extensions in one language, read from manifests alone: no JavaScript runs to decide
/// which columns there are.
public struct SourceCatalog: Sendable {
    public let descriptors: [SourceDescriptor]

    public init(installed: [InstalledExtension], language: String) {
        var descriptors: [SourceDescriptor] = []
        for entry in installed where entry.isUsable {
            guard let manifest = entry.manifest, let localization = entry.localization else { continue }
            func text(_ key: String) -> String { localization.string(key, language: language) }
            // The validator wants one or two actions; a source without any could not be run at all.
            for source in manifest.contributes.sources where !source.actions.isEmpty {
                let actions = source.actions.map { action in
                    SourceActionDescriptor(id: action.id, kind: action.kind, title: text(action.title), label: text(action.label),
                                           copyTitle: action.copyTitle.map(text), copied: action.copied.map(text))
                }
                descriptors.append(SourceDescriptor(extensionID: manifest.id, extensionName: text(manifest.name), sourceID: source.id,
                                                    title: text(source.title), sensitive: source.sensitive, actions: actions))
            }
        }
        self.descriptors = descriptors
    }
}
