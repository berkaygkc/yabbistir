import Foundation
import YabCore

/// Polls the pasteboard's change count (macOS has no change notification) and
/// hands filtered snapshots to `onCapture`, with the change count they were read at.
@MainActor
public final class PasteboardMonitor {
    public var filter: CaptureFilter

    private let reader: PasteboardReading
    private let apps: FrontmostAppProviding
    private let now: () -> Date
    private let onCapture: (CapturedClip, Int) -> Void
    private var lastChangeCount: Int
    private var appAtLastTick: SourceApp?
    private var ignoredChangeCounts: Set<Int> = []
    private var loop: Task<Void, Never>?

    public init(reader: PasteboardReading, apps: FrontmostAppProviding, filter: CaptureFilter,
                now: @escaping () -> Date = Date.init, onCapture: @escaping (CapturedClip, Int) -> Void) {
        self.reader = reader
        self.apps = apps
        self.filter = filter
        self.now = now
        self.onCapture = onCapture
        self.lastChangeCount = reader.changeCount
        self.appAtLastTick = apps.frontmostApplication()
    }

    /// One tick: captures the current pasteboard if it changed since the last tick.
    public func poll() {
        let frontmost = apps.frontmostApplication()
        defer { appAtLastTick = frontmost }
        let count = reader.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if ignoredChangeCounts.remove(count) != nil { return }

        let items = reader.readItems()
        let types = Set(items.flatMap { $0.map(\.type) })
        // The copy happened since the last tick, usually in the app that was in front then
        // (copy, then ⌘-Tab away). Skip it when either app is on the ignore list.
        let source = appAtLastTick ?? frontmost
        if let frontmost, frontmost != source, case .skip = filter.evaluate(types: types, source: frontmost) { return }
        guard case .capture(let device) = filter.evaluate(types: types, source: source) else { return }
        // A Universal Clipboard clip did not come from the app that happens to be in front.
        onCapture(CapturedClip(items: items, source: device == .remote ? nil : source, device: device, capturedAt: now()), count)
    }

    public func start(interval: Duration = .milliseconds(250)) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Marks a change yabbistir made itself (e.g. writing an item to paste it) so it is not re-captured.
    public func ignore(changeCount: Int) {
        ignoredChangeCounts.insert(changeCount)
    }
}
