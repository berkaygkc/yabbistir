import SwiftUI
import YabLocalization
import YabPlatform

/// What a paste from the panel does, given the preferences and the key that was pressed.
public struct PastePlan: Equatable {
    /// The value goes to the clipboard and nothing is typed into the app.
    public let copyOnly: Bool
    /// Only the plain text is used.
    public let plainText: Bool

    public init(copyOnly: Bool, plainText: Bool) {
        self.copyOnly = copyOnly
        self.plainText = plainText
    }

    public static func resolve(destination: PasteDestination, alwaysPlain: Bool, requestedPlain: Bool) -> PastePlan {
        PastePlan(copyOnly: destination == .clipboard, plainText: alwaysPlain || requestedPlain)
    }
}

/// Settings → Panel: where the panel opens, the preview delay, what ↵ does, plain text.
public struct PanelSettingsView: View {
    @Bindable var preferences: Preferences
    let language: LanguageStore

    public init(preferences: Preferences, language: LanguageStore) {
        self.preferences = preferences
        self.language = language
    }

    public var body: some View {
        Form {
            Section {
                Picker(string("settings.panel.position"), selection: $preferences.panelPosition) {
                    Text(string("settings.panel.position.caret")).tag(PanelPosition.caret)
                    Text(string("settings.panel.position.pointer")).tag(PanelPosition.pointer)
                }
                Picker(string("settings.panel.previewDelay"), selection: $preferences.previewDelay) {
                    Text(string("settings.panel.previewDelay.short")).tag(PreviewDelay.short)
                    Text(string("settings.panel.previewDelay.medium")).tag(PreviewDelay.medium)
                    Text(string("settings.panel.previewDelay.long")).tag(PreviewDelay.long)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker(string("settings.panel.returnKey"), selection: $preferences.pasteDestination) {
                    Text(string("settings.panel.returnKey.app")).tag(PasteDestination.app)
                    Text(string("settings.panel.returnKey.clipboard")).tag(PasteDestination.clipboard)
                }
                Toggle(string("settings.panel.alwaysPlain"), isOn: $preferences.alwaysPlainText)
                    .toggleStyle(.switch)
                Text(string("settings.panel.alwaysPlain.note")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(string("settings.section.panel"))
    }

    private func string(_ key: String) -> String { L10n.string(key, language.language) }
}
