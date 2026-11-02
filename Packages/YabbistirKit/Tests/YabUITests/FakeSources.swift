import Foundation
import YabExtensionKit
import YabExtensions
@testable import YabUI

/// A scripted source center for panel tests: states are set by hand, and every refresh is written down.
@MainActor
final class FakeSources: SourceProviding {
    var descriptors: [SourceDescriptor] = []
    var states: [String: SourceCenter.State] = [:]
    /// The keys of each `refresh`, in order.
    var refreshed: [[String]] = []
    var onChange: (() -> Void)?

    func state(of key: String) -> SourceCenter.State { states[key] ?? .idle }
    func refresh(_ keys: [String]) { refreshed.append(keys) }

    /// A list lands: the state changes and the panel hears of it, as `SourceCenter` tells it.
    func answer(_ key: String, _ state: SourceCenter.State) {
        states[key] = state
        onChange?()
    }

    /// A synthetic password vault: ↵ pastes the secret, ⇧↵ the username, which ⌘C also copies.
    static func vault(extensionID: String = "dev.example.kasa", sourceID: String = "vault", title: String = "Kasa") -> SourceDescriptor {
        SourceDescriptor(extensionID: extensionID, extensionName: title, sourceID: sourceID, title: title, sensitive: true, actions: [
            SourceActionDescriptor(id: "password", kind: .secret, title: "Şifreyi yapıştır", label: "Şifre"),
            SourceActionDescriptor(id: "username", kind: .text, title: "Kullanıcı adını yapıştır", label: "Kullanıcı adı",
                                   copyTitle: "Kullanıcı adını kopyala", copied: "Kullanıcı adı kopyalandı."),
        ])
    }
}
