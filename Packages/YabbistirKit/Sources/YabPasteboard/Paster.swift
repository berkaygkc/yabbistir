import Carbon.HIToolbox
import CoreGraphics
import Foundation
import YabCore

public protocol KeystrokePosting: AnyObject {
    func post(_ keystroke: PasteKeystroke, keyCode: CGKeyCode)
}

public final class CGEventKeystrokePoster: KeystrokePosting {
    public init() {}

    public func post(_ keystroke: PasteKeystroke, keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let flags: CGEventFlags = keystroke == .controlV ? .maskControl : .maskCommand
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            // The stack's ⌘V listener skips keystrokes that carry the marker.
            event?.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
            event?.post(tap: .cghidEventTap)
        }
    }
}

public enum CopiedOnlyReason: Equatable, Sendable {
    case accessibilityDenied, keyNotResolvable, secureInput
    /// The app it was meant for is no longer the one ⌘V would reach (`onlyIf`).
    case targetLeft
}

public enum PasteOutcome: Equatable, Sendable {
    case pasted, copiedOnly(CopiedOnlyReason)
}

/// Puts an item on the pasteboard and, when allowed, types the paste shortcut into the target app.
/// Without Accessibility the item still lands on the clipboard so nothing is silently lost.
@MainActor
public final class Paster {
    private let writer: PasteboardWriting
    private let resolver: KeyCodeResolver
    private let poster: KeystrokePosting
    private let isTrusted: () -> Bool
    private let isSecureInput: () -> Bool
    private let didWrite: (Int) -> Void

    public init(writer: PasteboardWriting, resolver: KeyCodeResolver, poster: KeystrokePosting,
                isTrusted: @escaping () -> Bool, isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() }, didWrite: @escaping (Int) -> Void) {
        self.writer = writer
        self.resolver = resolver
        self.poster = poster
        self.isTrusted = isTrusted
        self.isSecureInput = isSecureInput
        self.didWrite = didWrite
    }

    /// `onlyIf`: asked right before the keystroke, after the beat the target gets; false keeps the
    /// item on the clipboard and sends nothing. A finished job uses it so its result never lands in
    /// an app the person switched to in that beat.
    public func paste(_ items: [[PasteboardRepresentation]], kind: ItemKind, targetBundleID: String?, plainText: Bool,
                      onlyIf stillTarget: (() -> Bool)? = nil) async -> PasteOutcome {
        didWrite(writer.write(items, plainTextOnly: plainText))
        guard isTrusted() else { return .copiedOnly(.accessibilityDenied) }
        guard let keyCode = resolver.keyCode(for: "v") else { return .copiedOnly(.keyNotResolvable) }
        // Give the target app a beat to become key again after the panel hides.
        try? await Task.sleep(for: .milliseconds(30))
        // Secure Keyboard Entry (Terminal, iTerm, password fields) can swallow synthetic keystrokes.
        guard !isSecureInput() else { return .copiedOnly(.secureInput) }
        // Nothing awaits between this check and the keystroke.
        guard stillTarget?() ?? true else { return .copiedOnly(.targetLeft) }
        poster.post(PasteRules.keystroke(targetBundleID: targetBundleID, kind: kind), keyCode: keyCode)
        return .pasted
    }
}
