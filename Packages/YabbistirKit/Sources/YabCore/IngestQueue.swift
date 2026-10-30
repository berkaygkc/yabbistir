import Foundation

/// Stores captured clips off the main thread, one at a time in capture order, and reports each
/// stored item on the main actor. Hashing and writing a large copy (a 96 MB TIFF, 40 MB of rich
/// text) takes tens of milliseconds; the panel must not wait for it.
public final class IngestQueue: Sendable {
    /// Hears a clip's stored item id once `onIngested` has seen the item; nil when nothing was kept.
    public typealias Saved = @MainActor @Sendable (Int64?) -> Void

    private struct Pending: Sendable {
        var clip: CapturedClip
        var saved: Saved?
    }

    private let clips: AsyncStream<Pending>.Continuation

    public init(ingest: @escaping @Sendable (CapturedClip) throws -> IngestResult?,
                onIngested: @escaping @MainActor @Sendable (ClipItem) -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Pending.self)
        clips = continuation
        Task.detached(priority: .userInitiated) {
            for await pending in stream {
                let item = (try? ingest(pending.clip))?.item
                guard item != nil || pending.saved != nil else { continue }
                await MainActor.run {
                    if let item { onIngested(item) }
                    pending.saved?(item?.id)
                }
            }
        }
    }

    public convenience init(store: ItemStore, onIngested: @escaping @MainActor @Sendable (ClipItem) -> Void) {
        self.init(ingest: { try store.ingest($0) }, onIngested: onIngested)
    }

    /// `saved`: what the clip became, for whoever needs its id (capture rules file it in categories).
    public func submit(_ clip: CapturedClip, then saved: Saved? = nil) {
        clips.yield(Pending(clip: clip, saved: saved))
    }

    deinit {
        clips.finish()
    }
}
