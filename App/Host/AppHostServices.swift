import AppKit
import YabExtensionKit
import YabExtensions
import YabLocalization
import YabUI

/// What the app does when an extension asks, once `HostCallRouter` has checked the request: a notice, a link in the
/// browser, history, the on-device model, a translation. Nothing here logs what an extension sent or got back.
@MainActor
final class AppHostServices: HostServices {
    private let extensions: ExtensionService
    private let language: LanguageStore
    /// Made on first use: an app whose extensions never ask for the model or a translation never touches either.
    private lazy var onDevice = OnDeviceHostServices()
    private let notice = NoticeHUD()
    /// The open panel's frame; nil while it is closed. Set at launch, once the panel exists.
    var panelFrame: () -> CGRect? = { nil }
    /// Where a notice of the notice's size hangs while the panel is closed: from the menu bar status item, under the
    /// job card while that shows (`JobsSurfaceController.noticeOrigin`). Set at launch.
    var underStatusItem: ((CGSize) -> CGPoint)?

    init(extensions: ExtensionService, language: LanguageStore) {
        self.extensions = extensions
        self.language = language
    }

    /// Titled with the extension's name (the router has cut the message and spaced an extension's notices).
    func notify(extensionName: String, message: String) {
        show(.extensionMessage(name: extensionName, message: message))
    }

    /// The router found the pair's language pack missing: offered with its "Download". A run that failed for it shows
    /// nothing more (`HostCallRouter.failureNeedsNotice`).
    func offerTranslation(from: String, to: String) {
        show(.translationNeeded(from: from, to: to))
    }

    /// The router lets only http and https links with a host through.
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func recentItems(limit: Int) async -> [ExtensionItem] {
        await extensions.historyItems(recent: limit)
    }

    func searchItems(_ query: String, limit: Int) async -> [ExtensionItem] {
        await extensions.historyItems(matching: query, limit: limit)
    }

    /// The call's cancellation (its run ended, timed out or was cancelled) reaches the model through this await.
    func generate(_ prompt: String, options: AIOptions) async throws(ExtensionError) -> String {
        try await onDevice.generate(prompt, options: options, language: language.language)
    }

    func translate(_ text: String, from: String?, to: String) async throws(TranslationFailure) -> TranslationOutput {
        try await onDevice.translate(text, from: from, to: to, language: language.language)
    }

    /// Over the open panel, where its own notices go; with the panel closed, under the menu bar status item.
    func show(_ kind: NoticeKind) {
        if let frame = panelFrame() {
            notice.show(near: frame, language: language.language, kind: kind)
        } else if let underStatusItem {
            notice.show(language: language.language, kind: kind, origin: underStatusItem)
        }
    }
}
