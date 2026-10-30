import YabCore

public enum PasteKeystroke: Equatable, Sendable {
    case commandV, controlV, commandC
}

/// Per-app keystroke choices. Terminals paste images with ⌃V (terminal apps that read
/// the clipboard image do so on ⌃V; ⌘V only pastes text there).
public enum PasteRules {
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]

    public static func keystroke(targetBundleID: String?, kind: ItemKind) -> PasteKeystroke {
        guard let targetBundleID, terminalBundleIDs.contains(targetBundleID), kind == .image else { return .commandV }
        return .controlV
    }
}
