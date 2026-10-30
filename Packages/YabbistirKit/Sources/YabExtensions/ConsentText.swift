import Foundation
import YabExtensionKit
import YabLocalization

/// The sentences shown when a person is asked to approve an extension.
public enum ConsentText {
    public static func sentences(for manifest: ExtensionManifest, source: ExtensionSource, language: AppLanguage) -> [String] {
        var lines: [String] = []
        if manifest.permissions.contains("network") {
            let domains = manifest.network?.domains ?? []
            lines.append(domains.isEmpty
                ? L10n.string("permissions.network.any", language)
                : L10n.string("permissions.network.domains", language, domains.joined(separator: ", ")))
        }
        if manifest.permissions.contains("exec") {
            let tools = manifest.requires?.tools.map(\.name) ?? []
            lines.append(L10n.string("permissions.exec", language, tools.joined(separator: ", ")))
        }
        if manifest.permissions.contains("capture") { lines.append(L10n.string("permissions.capture", language)) }
        if manifest.permissions.contains("history") { lines.append(L10n.string("permissions.history", language)) }
        if source != .builtIn { lines.append(L10n.string("permissions.unsigned", language)) }
        return lines
    }
}
