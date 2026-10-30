import Foundation

/// What kind of app a result is pasted into.
public enum TargetClass: String, Codable, Sendable, CaseIterable { case finder, terminal, browser, editor, other }

/// The app a call's result is headed for.
public struct TargetInfo: Codable, Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var kind: TargetClass

    public init(bundleID: String, name: String, kind: TargetClass) { (self.bundleID, self.name, self.kind) = (bundleID, name, kind) }
}

/// Sorts a bundle id into a `TargetClass`. The terminal list is a copy of the paste rules' list
/// (this module does not depend on YabPasteboard); a test keeps the two equal.
public enum TargetClassifier {
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
        "app.zen-browser.zen",
    ]

    static let editors: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.sublimetext.4", "com.panic.Nova", "com.barebones.bbedit", "com.apple.TextEdit", "com.coteditor.CotEditor",
    ]

    public static func classify(bundleID: String?) -> TargetClass {
        guard let bundleID else { return .other }
        if bundleID == "com.apple.finder" { return .finder }
        if terminals.contains(bundleID) { return .terminal }
        if browsers.contains(bundleID) { return .browser }
        if editors.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") { return .editor }
        return .other
    }
}
