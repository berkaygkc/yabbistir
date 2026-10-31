import Foundation
import YabExtensionKit
import YabLocalization

/// The sentences shown when a person is asked to approve an extension.
public enum ConsentText {
    public static func sentences(for manifest: ExtensionManifest, source: ExtensionSource, language: AppLanguage) -> [String] {
        var lines = sentences(permissions: manifest.permissions, domains: manifest.network?.domains ?? [],
                              tools: manifest.requires?.tools.map(\.name) ?? [], language: language)
        if source != .builtIn { lines.append(L10n.string("permissions.unsigned", language)) }
        return lines
    }

    /// One sentence per permission, in a fixed order: the network (any website, or the sites listed), the programs
    /// it runs, copies, history. A store catalog entry is described this way before it is downloaded.
    public static func sentences(permissions: [String], domains: [String], tools: [String], language: AppLanguage) -> [String] {
        var lines: [String] = []
        if permissions.contains("network") {
            lines.append(domains.isEmpty
                ? L10n.string("permissions.network.any", language)
                : L10n.string("permissions.network.domains", language, domains.joined(separator: ", ")))
        }
        if permissions.contains("exec") {
            lines.append(L10n.string("permissions.exec", language, tools.joined(separator: ", ")))
        }
        if permissions.contains("capture") { lines.append(L10n.string("permissions.capture", language)) }
        if permissions.contains("history") { lines.append(L10n.string("permissions.history", language)) }
        return lines
    }
}
