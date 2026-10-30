import SwiftUI
import YabLocalization

/// What a notice is about, which decides what it asks the user to do.
public enum NoticeKind: Equatable, Sendable {
    /// No Accessibility permission: offer the settings pane.
    case accessibility
    /// Secure Keyboard Entry is on in the target app: the user pastes with ⌘V.
    case secureInput
    /// The Sıra cannot hear ⌘V without Input Monitoring: offer the settings pane.
    case inputMonitoring
    /// The target app left (or the panel came back) before ⌘V: the item waits on the clipboard.
    case copiedOnly
    /// A command failed: which extension, and its message.
    case extensionFailed(name: String, message: String)
    /// The host turned an extension off after repeated errors.
    case extensionDisabled(name: String)
    /// An action answered with only a message (`{none, message}`): the extension's name over its
    /// own words, already in the person's language. Not a failure.
    case extensionMessage(name: String, message: String)
    /// A translation needs a language pack that is not downloaded (BCP-47 codes): offer the download.
    case translationNeeded(from: String, to: String)
    /// "Check for Updates…" found nothing newer than the running version.
    case upToDate(version: String)
    /// A newer release exists: offer its page.
    case updateAvailable(version: String, page: URL)
    /// "Check for Updates…" could not tell (no network, an odd answer). Never worded as "up to date".
    case updateCheckFailed

    func titleText(_ language: AppLanguage) -> String {
        switch self {
        case .inputMonitoring: L10n.string("notice.inputMonitoring.title", language)
        case .accessibility, .secureInput: L10n.string("notice.copiedOnly.title", language)
        case .copiedOnly: L10n.string("notice.copiedOnly", language)
        case .extensionFailed, .extensionDisabled: L10n.string("notice.extensionFailed.title", language)
        case .extensionMessage(let name, _): name
        case .translationNeeded: L10n.string("notice.translationNeeded.title", language)
        case .upToDate(let version): L10n.string("notice.update.upToDate", language, version)
        case .updateAvailable(let version, _): L10n.string("notice.update.available", language, version)
        case .updateCheckFailed: L10n.string("notice.update.failed", language)
        }
    }

    func bodyText(_ language: AppLanguage) -> String {
        switch self {
        case .accessibility: L10n.string("notice.copiedOnly.body", language)
        case .secureInput: L10n.string("notice.secureInput.body", language)
        case .copiedOnly: ""
        case .inputMonitoring: L10n.string("notice.inputMonitoring.body", language)
        case .extensionFailed(let name, let message): L10n.string("notice.extensionFailed.body", language, name, message)
        case .extensionDisabled(let name): L10n.string("notice.extensionDisabled.body", language, name)
        case .extensionMessage(_, let message): message
        case .translationNeeded(let from, let to): LanguageNames.pair(from: from, to: to, in: language)
        case .upToDate, .updateAvailable, .updateCheckFailed: ""
        }
    }

    /// What the notice's one button does; nil when it has none (and then it does nothing).
    public var action: NoticeAction? {
        switch self {
        case .accessibility: .accessibilitySettings
        case .inputMonitoring: .inputMonitoringSettings
        case .translationNeeded(let from, let to): .downloadLanguagePack(from: from, to: to)
        case .updateAvailable(_, let page): .openURL(page)
        case .secureInput, .copiedOnly, .extensionFailed, .extensionDisabled, .extensionMessage, .upToDate, .updateCheckFailed: nil
        }
    }

    /// The one button, when the notice offers something to do.
    func actionText(_ language: AppLanguage) -> String? {
        switch action {
        case .accessibilitySettings, .inputMonitoringSettings: L10n.string("notice.copiedOnly.action", language)
        case .downloadLanguagePack, .openURL: L10n.string("notice.translationDownload", language)
        case nil: nil
        }
    }

    /// How long the notice stays up: an offer waits 8 s, so there is time to take it (a click closes it sooner); the
    /// rest 4 s.
    public var duration: Duration { action == nil ? .seconds(4) : .seconds(8) }

    /// Permission notices carry a button to the settings pane.
    var offersSettings: Bool { self == .accessibility || self == .inputMonitoring }
}

/// A notice's button: a settings pane the notice asks for, or a language pack to download (BCP-47 codes).
public enum NoticeAction: Equatable, Sendable {
    case accessibilitySettings
    case inputMonitoringSettings
    case downloadLanguagePack(from: String, to: String)
    /// A page to open in the browser (the release page of a newer version).
    case openURL(URL)
}

/// Shown when an item could only be copied, not pasted, when the Sıra lacks a permission, when
/// an extension failed, when an action answered with a message, or when a translation needs a
/// language pack.
public struct NoticeView: View {
    let language: AppLanguage
    let kind: NoticeKind
    /// The button's work: open the settings pane, or download the language pack.
    let action: () -> Void

    public init(language: AppLanguage, kind: NoticeKind, action: @escaping () -> Void) {
        self.language = language
        self.kind = kind
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppMark()
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.titleText(language))
                    .font(Tokens.Fonts.labelStrong).foregroundStyle(Tokens.Colors.text)
                if !kind.bodyText(language).isEmpty {
                    Text(kind.bodyText(language))
                        .font(Tokens.Fonts.label).foregroundStyle(Tokens.Colors.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: 360, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let title = kind.actionText(language) {
                Button(action: action) {
                    Text(title)
                        .font(Tokens.Fonts.labelStrong)
                        .foregroundStyle(Tokens.Colors.text)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Tokens.Colors.keycapFill, in: RoundedRectangle(cornerRadius: Tokens.Metrics.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(PanelBackground(material: PanelMaterial.current, cornerRadius: 12))
        .fixedSize()
    }
}
