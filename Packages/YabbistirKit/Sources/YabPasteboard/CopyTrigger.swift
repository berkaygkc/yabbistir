import CoreGraphics
import Foundation

/// Copies the frontmost app's selection for ⌘⇧C: posts ⌘C and waits for the clipboard to change.
@MainActor
public final class CopyTrigger {
    private let reader: PasteboardReading
    private let resolver: KeyCodeResolver
    private let poster: KeystrokePosting
    private let timeout: Duration
    private let keysHeld: () -> Bool
    private let keyWait: Duration

    public init(reader: PasteboardReading, resolver: KeyCodeResolver, poster: KeystrokePosting, timeout: Duration = .milliseconds(300),
                keysHeld: @escaping () -> Bool = CopyTrigger.extraKeysHeld, keyWait: Duration = .seconds(1)) {
        self.reader = reader
        self.resolver = resolver
        self.poster = poster
        self.timeout = timeout
        self.keysHeld = keysHeld
        self.keyWait = keyWait
    }

    /// Whether ⇧, ⌥ or ⌃ is down on the keyboard itself. ⌘ may stay down: a ⌘C typed with ⌘ held is the usual one.
    public nonisolated static func extraKeysHeld() -> Bool {
        !CGEventSource.flagsState(.hidSystemState).intersection([.maskShift, .maskAlternate, .maskControl]).isEmpty
    }

    /// False when nothing reached the clipboard in time (no selection, or no C key on the layout).
    public func copy() async -> Bool {
        guard let keyCode = resolver.keyCode(for: "c") else { return false }
        // ⌘⇧C fires as C comes up, ⇧ often still down. Terminal reads the keys held, not the ⌘C's own, and beeps at
        // ⇧⌘C; so ⌘C waits for ⇧, ⌥ and ⌃ to come up, a moment at most.
        let keysDeadline = ContinuousClock.now + keyWait
        while keysHeld(), ContinuousClock.now < keysDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let before = reader.changeCount
        poster.post(.commandC, keyCode: keyCode)
        let deadline = ContinuousClock.now + timeout
        while reader.changeCount == before {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
