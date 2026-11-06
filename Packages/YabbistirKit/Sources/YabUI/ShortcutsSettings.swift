import SwiftUI
import YabLocalization
import YabPlatform

/// One line of the panel's key reference: the keys, and what they do.
public struct PanelKeyReference: Sendable {
    public let keys: [String]
    public let titleKey: String
    /// A title can have two keys (⇧ and ⌘T both open the ⇧ panel).
    public var id: String { titleKey + keys.joined() }

    public static let all: [PanelKeyReference] = [
        .init(keys: ["↑", "↓"], titleKey: "settings.keys.move"),
        .init(keys: ["←", "→"], titleKey: "settings.keys.columns"),
        .init(keys: ["↵"], titleKey: "settings.keys.paste"),
        .init(keys: ["⇧", "↵"], titleKey: "settings.keys.shiftReturn"),
        .init(keys: ["⇧"], titleKey: "settings.keys.transforms"),
        // Under an input method a ⇧ tap is the method's; ⌘T works with any keyboard.
        .init(keys: ["⌘", "T"], titleKey: "settings.keys.transforms"),
        .init(keys: ["⌘", "K"], titleKey: "settings.keys.actions"),
        .init(keys: ["⌘", "C"], titleKey: "settings.keys.copy"),
        .init(keys: ["⌘", "P"], titleKey: "settings.keys.addToCategory"),
        .init(keys: ["⌘", "E"], titleKey: "settings.keys.editCategories"),
        .init(keys: ["⌘", "1–9"], titleKey: "settings.keys.quickPaste"),
        .init(keys: ["esc"], titleKey: "settings.keys.close"),
    ]
}

/// Settings → Shortcuts: record the two global shortcuts, and see the keys the panel answers to.
public struct ShortcutsSettingsView: View {
    let language: LanguageStore

    public init(language: LanguageStore) {
        self.language = language
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent(string("settings.shortcuts.togglePanel")) { ShortcutRecorder(.togglePanel) }
                LabeledContent(string("settings.shortcuts.stackCopy")) { ShortcutRecorder(.stackCopy) }
                Button(string("settings.shortcuts.reset")) { GlobalShortcuts.resetToDefaults() }
            } header: {
                Text(string("settings.shortcuts.global"))
            }
            Section {
                ForEach(PanelKeyReference.all, id: \.id) { row in
                    LabeledContent {
                        HStack(spacing: 3) { ForEach(row.keys, id: \.self) { Keycap($0) } }
                    } label: {
                        Text(string(row.titleKey))
                    }
                }
            } header: {
                Text(string("settings.shortcuts.inPanel"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(string("settings.section.shortcuts"))
    }

    private func string(_ key: String) -> String { L10n.string(key, language.language) }
}
