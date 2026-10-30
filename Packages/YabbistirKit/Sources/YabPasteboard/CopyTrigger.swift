import Foundation

/// Copies the frontmost app's selection for ⌘⇧C: posts ⌘C and waits for the clipboard to change.
@MainActor
public final class CopyTrigger {
    private let reader: PasteboardReading
    private let resolver: KeyCodeResolver
    private let poster: KeystrokePosting
    private let timeout: Duration

    public init(reader: PasteboardReading, resolver: KeyCodeResolver, poster: KeystrokePosting, timeout: Duration = .milliseconds(300)) {
        self.reader = reader
        self.resolver = resolver
        self.poster = poster
        self.timeout = timeout
    }

    /// False when nothing reached the clipboard in time (no selection, or no C key on the layout).
    public func copy() async -> Bool {
        guard let keyCode = resolver.keyCode(for: "c") else { return false }
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
