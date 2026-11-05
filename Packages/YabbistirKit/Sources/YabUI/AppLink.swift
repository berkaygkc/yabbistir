import Foundation
import YabExtensionKit

/// What a `yabbistir://` link asks for. The website's Install buttons open
/// `yabbistir://store/install?id=<extension id>` (`id` may repeat); `yabbistir://store` opens the Store. Any other
/// address only brings yabbistir forward. A link never installs anything itself: an install link picks the extensions
/// in the Store and shows the same consent sheet as Install (N).
public enum AppLink: Equatable, Sendable {
    /// Settings › Extensions › Store.
    case store
    /// The Store with these extensions picked and the consent sheet up: never empty, at most `maxIDs`, in the order
    /// the link gives them, each once.
    case install(ids: [String])
    /// Any other address: the app comes forward and nothing else happens.
    case other

    public static let scheme = "yabbistir"
    /// Ids after this many are ignored: the store holds a few dozen extensions, and one sheet should stay readable.
    public static let maxIDs = 20
    /// A longer id is ignored.
    public static let maxIDLength = 128

    public init(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "store",
              components.user == nil, components.password == nil, components.port == nil else {
            self = .other
            return
        }
        switch components.path {
        case "", "/":
            self = .store
        case "/install", "/install/":
            let ids = Self.ids(in: components.queryItems ?? [])
            // Nothing well formed to offer: the Store still opens, as the link meant to show it.
            self = ids.isEmpty ? .store : .install(ids: ids)
        default:
            self = .other
        }
    }

    /// The well-formed `id` values, each once and at most `maxIDs` of them; anything else is skipped.
    static func ids(in items: [URLQueryItem]) -> [String] {
        var ids: [String] = []
        for item in items where item.name == "id" {
            guard let id = item.value, isValidID(id), !ids.contains(id) else { continue }
            ids.append(id)
            if ids.count == maxIDs { break }
        }
        return ids
    }

    /// A lowercase reverse-domain id, as manifests require ("dev.yabbistir.jwt"), and not too long: only ASCII letters,
    /// digits, dots and dashes, so a path or a line break never reaches the Store.
    static func isValidID(_ id: String) -> Bool {
        id.utf8.count <= maxIDLength && ManifestValidator.isValidID(id)
    }
}
