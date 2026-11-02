import AppKit
import Observation
import SwiftUI
import YabLocalization

/// Settings → About: the version, the project's links, and the bundled licenses.
@MainActor @Observable
public final class AboutModel {
    public static let repository = URL(string: "https://github.com/berkaygkc/yabbistir")!
    public static let releases = URL(string: "https://github.com/berkaygkc/yabbistir/releases")!
    public static let sponsors = URL(string: "https://github.com/sponsors/berkaygkc")!

    public let languageStore: LanguageStore
    public let version: String
    public let build: String
    @ObservationIgnored private let checkForUpdatesAction: () -> Void
    @ObservationIgnored private let readNotice: (String) -> String?
    @ObservationIgnored private let openURL: (URL) -> Void

    public init(version: String, build: String, language: LanguageStore,
                checkForUpdates: @escaping () -> Void, readNotice: @escaping (String) -> String?,
                openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.version = version
        self.build = build
        self.languageStore = language
        self.checkForUpdatesAction = checkForUpdates
        self.readNotice = readNotice
        self.openURL = openURL
    }

    public var language: AppLanguage { languageStore.language }

    public var versionText: String { L10n.string("settings.about.version", language, version, build) }

    /// The project's license and the third-party notices, one after the other.
    public var licensesText: String {
        ["LICENSE", "THIRD_PARTY_NOTICES.md"].compactMap(readNotice).joined(separator: "\n\n")
    }

    public func checkForUpdates() { checkForUpdatesAction() }

    public func open(_ url: URL) { openURL(url) }
}

public struct AboutSettingsView: View {
    let model: AboutModel
    @State private var showsLicenses = false

    public init(model: AboutModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("yabbistir").font(.title2.weight(.semibold))
                    Text(model.versionText).foregroundStyle(.secondary).monospacedDigit()
                    Text(string("settings.about.tagline")).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                Button(string("settings.about.checkForUpdates")) { model.checkForUpdates() }
                Button(string("settings.about.github")) { model.open(AboutModel.repository) }
                Button(string("settings.about.releaseNotes")) { model.open(AboutModel.releases) }
                Button(string("settings.about.licenses")) { showsLicenses = true }
            }
            Section {
                Button { model.open(AboutModel.sponsors) } label: {
                    Label(string("settings.about.support"), systemImage: "heart")
                }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(string("settings.section.about"))
        .sheet(isPresented: $showsLicenses) {
            VStack(spacing: 0) {
                ScrollView {
                    Text(model.licensesText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                Divider()
                HStack {
                    Spacer()
                    Button(string("settings.done")) { showsLicenses = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
            .frame(width: 520, height: 420)
            .environment(\.locale, model.language.locale)
        }
    }

    private func string(_ key: String) -> String { L10n.string(key, model.language) }
}
