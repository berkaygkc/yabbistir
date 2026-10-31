import Foundation
import YabExtensionKit

/// What the app does when an extension asks (through `HostCallRouter`, which has already checked the
/// request): show a notice, open a link, read history, run the on-device model, translate.
@MainActor public protocol HostServices: AnyObject {
    /// A short notice titled with the extension's name.
    func notify(extensionName: String, message: String)
    /// An http or https link, in the default browser.
    func open(_ url: URL)
    func recentItems(limit: Int) async -> [ExtensionItem]
    func searchItems(_ query: String, limit: Int) async -> [ExtensionItem]
    /// The on-device model's answer (`OnDeviceHostServices.generate`).
    func generate(_ prompt: String, options: AIOptions) async throws(ExtensionError) -> String
    /// `text` in `to`, from `from` or the language it is recognized as (`OnDeviceHostServices.translate`).
    func translate(_ text: String, from: String?, to: String) async throws(TranslationFailure) -> TranslationOutput
}

/// Why `translate` failed: what the extension is told, and, when the pair itself was the problem, why,
/// so the router can offer a language pack that is not downloaded.
public struct TranslationFailure: Error, Equatable, Sendable {
    /// What the extension is told, in the app's language.
    public var error: ExtensionError
    public var reason: TranslationUnavailable?

    public init(_ error: ExtensionError, reason: TranslationUnavailable? = nil) {
        (self.error, self.reason) = (error, reason)
    }
}
