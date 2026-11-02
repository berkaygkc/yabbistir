import AppKit
import YabCore

/// The clipboard as a source's value sees it: one value written on its own, and what was there before it.
public protocol SensitivePasteboard: AnyObject {
    var changeCount: Int { get }
    /// Every type of every item, to put back later.
    func snapshot() -> [[PasteboardRepresentation]]
    /// Replaces the clipboard with `text` alone and returns the new change count.
    func write(_ text: String, concealed: Bool) -> Int
    /// Puts a snapshot back and returns the new change count.
    func restore(_ items: [[PasteboardRepresentation]]) -> Int
}

/// `SensitivePasteboard` on a real pasteboard. Everything it writes stays on this Mac (never Universal Clipboard).
/// A value carries the nspasteboard.org markers: transient always, concealed for a secret, and the app as its
/// source, so clipboard managers (this one too) keep it out of their history.
public final class SystemSensitivePasteboard: SensitivePasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    private let pasteboard: NSPasteboard
    private let sourceID: String

    /// `sourceID`: the app's bundle identifier, written as the value's source.
    public init(pasteboard: NSPasteboard = .general, sourceID: String) {
        self.pasteboard = pasteboard
        self.sourceID = sourceID
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> [[PasteboardRepresentation]] {
        SystemPasteboardReader(pasteboard: pasteboard).readItems()
    }

    public func write(_ text: String, concealed: Bool) -> Int {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        if concealed { item.setData(Data(), forType: Self.concealedType) }
        item.setData(Data(sourceID.utf8), forType: Self.sourceType)
        return replaceLocally(with: [item])
    }

    public func restore(_ items: [[PasteboardRepresentation]]) -> Int {
        // An item no type could be read from has nothing to put back.
        let objects = items.filter { !$0.isEmpty }.map { reps in
            let item = NSPasteboardItem()
            for rep in reps { item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
            return item
        }
        guard !objects.isEmpty else {
            pasteboard.clearContents()
            return pasteboard.changeCount
        }
        // What was there may be another app's secret: it goes back local too.
        return replaceLocally(with: objects)
    }

    private func replaceLocally(with items: [NSPasteboardItem]) -> Int {
        // Clears the pasteboard, and keeps what follows off the other devices.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }
}

/// Pastes or copies a source's value without it ever entering history.
@MainActor
public protocol SensitivePasting: AnyObject {
    /// Writes `text` and types ⌘V, only while the clipboard still holds it and `onlyIf` (when given) says yes. A secret
    /// (`concealed`) gives the clipboard back afterwards; text stays.
    /// `restoreInstead` takes the place of that give-back (the paste stack puts its own head back); if it writes
    /// nothing, the give-back still happens.
    func paste(_ text: String, concealed: Bool, targetBundleID: String?, onlyIf: (() -> Bool)?,
               restoreInstead: (() -> Void)?) async -> PasteOutcome
    /// Writes `text` the same way, as text, and types nothing.
    func copy(_ text: String)
}

/// Writes a source's value on its own and, for a secret, gives back the clipboard it replaced: `restoreDelay`
/// after ⌘V, at once when the target left, and after `copiedOnlyLifetime` when it was only copied. A give-back
/// happens only while the clipboard still holds the secret, so a newer copy is never overwritten.
@MainActor
public final class SensitivePaste: SensitivePasting {
    /// A secret on the clipboard, waiting to give it back.
    private struct Pending {
        /// The clipboard from before the first of the secrets pasted in a row.
        let snapshot: [[PasteboardRepresentation]]
        /// The secret's change count; any other means the clipboard has moved on.
        let written: Int
        let restoreInstead: (() -> Void)?
        var timer: Task<Void, Never>?
    }

    private let board: SensitivePasteboard
    private let send: @MainActor (_ target: String?, _ onlyIf: (() -> Bool)?) async -> PasteOutcome
    private let didWrite: (Int) -> Void
    private let restoreDelay: Duration
    private let copiedOnlyLifetime: Duration
    private var pending: Pending?

    /// `send`: the steps after the write (`Paster.send`). `didWrite` gets every new change count, the give-back's
    /// too, so the monitor skips them (`PasteboardMonitor.ignore`).
    public init(board: SensitivePasteboard,
                send: @escaping @MainActor (_ target: String?, _ onlyIf: (() -> Bool)?) async -> PasteOutcome,
                didWrite: @escaping (Int) -> Void,
                restoreDelay: Duration = .seconds(1), copiedOnlyLifetime: Duration = .seconds(30)) {
        self.board = board
        self.send = send
        self.didWrite = didWrite
        self.restoreDelay = restoreDelay
        self.copiedOnlyLifetime = copiedOnlyLifetime
    }

    /// The wait before a pending give-back; tests await it.
    var pendingRestore: Task<Void, Never>? { pending?.timer }

    public func paste(_ text: String, concealed: Bool, targetBundleID: String?, onlyIf: (() -> Bool)?,
                      restoreInstead: (() -> Void)?) async -> PasteOutcome {
        guard concealed else {
            let written = write(text)
            return await send(targetBundleID, holding(written, onlyIf))
        }
        // A secret pasted while another still waits keeps that one's clipboard: the person's, not the first secret.
        // One the clipboard moved on from has nothing left to give back.
        let carried = pending.flatMap { board.changeCount == $0.written ? $0.snapshot : nil }
        drop()
        let snapshot = carried ?? board.snapshot()
        let written = board.write(text, concealed: true)
        didWrite(written)
        pending = Pending(snapshot: snapshot, written: written, restoreInstead: restoreInstead)
        let outcome = await send(targetBundleID, holding(written, onlyIf))
        // A newer value, a copy or a flush may have taken its place during the send.
        guard pending?.written == written else { return outcome }
        switch outcome {
        case .pasted: restore(after: restoreDelay)
        case .copiedOnly(.targetLeft): restore()
        case .copiedOnly: restore(after: copiedOnlyLifetime)
        }
        return outcome
    }

    public func copy(_ text: String) {
        write(text)
    }

    /// Restores a pending secret now (screen lock, quit).
    public func flush() {
        restore()
    }

    /// Text stays on the clipboard; a secret still waiting has nothing to give back over it.
    @discardableResult
    private func write(_ text: String) -> Int {
        drop()
        let written = board.write(text, concealed: false)
        didWrite(written)
        return written
    }

    /// ⌘V goes only while the clipboard still holds the value: a flush, another value or a copy (from this Mac or
    /// another device) that took its place in the beat before the keystroke is never pasted instead.
    private func holding(_ written: Int, _ onlyIf: (() -> Bool)?) -> () -> Bool {
        { [board] in board.changeCount == written && (onlyIf?() ?? true) }
    }

    private func restore(after delay: Duration) {
        pending?.timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            // Cancelled after the wait, before its turn came.
            guard !Task.isCancelled else { return }
            self?.restore()
        }
    }

    private func restore() {
        guard let pending else { return }
        drop()
        // A newer copy (the person's, another app's) is never overwritten.
        guard board.changeCount == pending.written else { return }
        if let restoreInstead = pending.restoreInstead {
            restoreInstead()
            // The paste stack put its head back; one that finished meanwhile had none, and the secret still goes.
            guard board.changeCount == pending.written else { return }
        }
        didWrite(board.restore(pending.snapshot))
    }

    private func drop() {
        pending?.timer?.cancel()
        pending = nil
    }
}
