import Observation
import SwiftUI
import YabLocalization
import YabPlatform

/// Settings → General: what the page edits, and the login item's real state.
@MainActor @Observable
public final class GeneralSettingsModel {
    public let preferences: Preferences
    public let languageStore: LanguageStore
    @ObservationIgnored private let loginItem: LoginItemControlling
    public private(set) var loginStatus: LoginItemStatus
    /// The last change to the login item failed.
    public private(set) var loginFailed = false

    public init(preferences: Preferences, language: LanguageStore, loginItem: LoginItemControlling) {
        self.preferences = preferences
        self.languageStore = language
        self.loginItem = loginItem
        loginStatus = loginItem.status
    }

    public var language: AppLanguage { languageStore.language }

    /// On, or waiting for the person's approval in System Settings.
    public var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    public var showsLaunchAtLogin: Bool { loginStatus != .unavailable }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginFailed = false
        } catch {
            loginFailed = true
        }
        loginStatus = loginItem.status
    }

    /// Reads the system again (the person may have changed it in System Settings).
    public func refresh() {
        loginStatus = loginItem.status
    }

    public func openSystemSettings() {
        loginItem.openSystemSettings()
    }
}

public struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettingsModel

    public init(model: GeneralSettingsModel) {
        self.model = model
    }

    public var body: some View {
        @Bindable var preferences = model.preferences
        @Bindable var languageStore = model.languageStore
        return Form {
            Section {
                Picker(string("settings.general.language"), selection: $languageStore.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.nativeName).tag($0) }
                }
                Picker(string("settings.general.appearance"), selection: $preferences.appearance) {
                    Text(string("settings.general.appearance.system")).tag(AppearanceChoice.system)
                    Text(string("settings.general.appearance.light")).tag(AppearanceChoice.light)
                    Text(string("settings.general.appearance.dark")).tag(AppearanceChoice.dark)
                }
                .pickerStyle(.segmented)
            }
            if model.showsLaunchAtLogin {
                Section {
                    Toggle(string("settings.general.launchAtLogin"),
                           isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                    if model.loginStatus == .requiresApproval {
                        note("settings.general.launchAtLogin.approval")
                        Button(string("settings.openSystemSettings")) { model.openSystemSettings() }
                    }
                    if model.loginFailed {
                        note("settings.general.launchAtLogin.failed")
                    }
                }
            }
            Section {
                Toggle(string("settings.general.menuBarIcon"), isOn: $preferences.showsMenuBarIcon)
                    .toggleStyle(.switch)
                note("settings.general.menuBarIcon.note")
            }
            Section {
                Toggle(string("settings.general.hideFromSharing"), isOn: $preferences.hidesFromScreenSharing)
                    .toggleStyle(.switch)
                note("settings.general.hideFromSharing.note")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(string("settings.section.general"))
        .onAppear { model.refresh() }
    }

    private func string(_ key: String) -> String { L10n.string(key, model.language) }

    private func note(_ key: String) -> some View {
        Text(string(key)).font(.callout).foregroundStyle(.secondary)
    }
}
