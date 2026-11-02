import Foundation
import Observation
import YabCore
import YabPasteboard

public struct StackEntry: Identifiable, Equatable, Sendable {
    /// Unique in the session: the same item can be queued twice.
    public let id: Int
    public let itemID: Int64
}

public struct StackTiming: Sendable {
    /// The new-copy rail, and ⌥1/⌥2 with it, live this long: 7 s.
    public var rail: Duration
    /// After a ⌘V, the target app reads the clipboard before the next item replaces it.
    public var settle: Duration
    /// An emptied stack closes after this pause.
    public var closeDelay: Duration

    public init(rail: Duration = .seconds(7), settle: Duration = .milliseconds(250), closeDelay: Duration = .milliseconds(900)) {
        self.rail = rail
        self.settle = settle
        self.closeDelay = closeDelay
    }
}

/// The paste stack (Sıra): copies line up, the head sits on the general clipboard, and each
/// ⌘V the user makes pastes it and brings the next one up. Lives in memory; items stay in history.
@MainActor @Observable
public final class StackSession {
    public private(set) var entries: [StackEntry] = []
    public private(set) var isOpen = false
    /// The copy the rail offers to move to the top or second place.
    public private(set) var recentEntryID: Int?
    /// The rail shows while its copy waits behind the head; once that copy is next it has nothing to offer.
    public var isRailVisible: Bool { recentIndex.map { $0 > 0 } ?? false }
    /// ⌥2 is offered only when it would move the copy: a third item, and the copy not already second.
    public var offersSecondPlace: Bool { isRailVisible && entries.count > 2 && recentIndex != 1 }
    /// ⌥1 is registered as a global shortcut only while this is true (⌥2 also needs `offersSecondPlace`).
    public var wantsRailShortcuts: Bool { isRailVisible }
    /// How long the rail stays (its countdown bar drains over this).
    public var railDuration: Duration { timing.rail }
    /// How long a target app gets to read the clipboard after a ⌘V.
    public var settleDuration: Duration { timing.settle }
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let writer: PasteboardWriting
    @ObservationIgnored private let didWrite: (Int) -> Void
    @ObservationIgnored private let timing: StackTiming
    /// The clipboard's change count now; nil skips the check below (tests that do not need it).
    @ObservationIgnored private let currentChangeCount: (() -> Int)?
    /// The change count of the stack's last write: a ⌘V pastes the head only while it still matches.
    @ObservationIgnored private var headChangeCount: Int?
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var railTimer: Task<Void, Never>?
    @ObservationIgnored private var pasteTimer: Task<Void, Never>?
    /// Items whose ⌘V was held while an earlier paste settled; they paste in this order.
    @ObservationIgnored private var outgoing: [StackEntry] = []
    /// Posts a marked ⌘V for a held keystroke.
    @ObservationIgnored private let replayPaste: (() -> Void)?
    /// Whether the clipboard gets plain text alone (asked at each write, so a change applies at once).
    @ObservationIgnored private let plainText: @MainActor () -> Bool
    @ObservationIgnored private var closeTimer: Task<Void, Never>?

    public init(library: Library, writer: PasteboardWriting, didWrite: @escaping (Int) -> Void,
                changeCount: (() -> Int)? = nil, replayPaste: (() -> Void)? = nil, timing: StackTiming = .init(),
                plainText: @escaping @MainActor () -> Bool = { false }) {
        self.library = library
        self.writer = writer
        self.didWrite = didWrite
        self.currentChangeCount = changeCount
        self.replayPaste = replayPaste
        self.timing = timing
        self.plainText = plainText
    }

    private var recentIndex: Int? { recentEntryID.flatMap { id in entries.firstIndex { $0.id == id } } }

    /// ⌘⇧C with nothing selected: an empty stack that waits for the first copy.
    public func open() {
        guard !isOpen else { return }
        closeTimer?.cancel()
        isOpen = true
        changed()
    }


    /// A copy joins the end; the first one opens the stack. The clipboard goes back to the head.
    public func append(_ itemID: Int64) {
        closeTimer?.cancel()
        let entry = StackEntry(id: nextID, itemID: itemID)
        nextID += 1
        entries.append(entry)
        isOpen = true
        if entries.count > 1 { showRail(for: entry.id) }
        writeHead()
        changed()
    }

    public func move(entryID: Int, to index: Int) {
        guard let from = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let target = max(0, min(index, entries.count - 1))
        guard from != target else { return }
        let headBefore = entries.first?.id
        entries.insert(entries.remove(at: from), at: target)
        endRail()
        if entries.first?.id != headBefore { writeHead() }
        changed()
    }

    /// ⌥1 → top, ⌥2 → second place, for the copy the rail shows.
    public func moveRecent(to index: Int) {
        guard let id = recentEntryID ?? entries.last?.id else { return }
        move(entryID: id, to: index)
        endRail()
    }

    public func remove(entryID: Int) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries.remove(at: index)
        if recentEntryID == entryID { endRail() }
        if index == 0 { writeHead() }
        closeIfEmpty()
        changed()
    }

    /// The user pressed ⌘V somewhere; returns whether the keystroke may go through.
    ///
    /// The head leaves the stack at once and stays on the clipboard until the target has read it
    /// (the settle pause); then the next one takes its place. A ⌘V pressed during that pause is
    /// held and replayed once its own item is on the clipboard, so quick presses paste one item
    /// each, in order. Key repeats from a held-down ⌘V are held too. A tap that can only listen
    /// (`canHold` false) lets such a press through uncounted. When the clipboard no longer holds the
    /// head (a copy the stack skipped, a snippet tool), the ⌘V pastes that instead: the head stays
    /// and goes back on the clipboard.
    @discardableResult
    public func userPasted(isRepeat: Bool = false, canHold: Bool = true) -> Bool {
        guard isOpen else { return true }
        if pasteTimer != nil {
            guard canHold else { return true }
            if !isRepeat, !entries.isEmpty { outgoing.append(takeHead()) }
            return false
        }
        guard !entries.isEmpty, !isRepeat else { return true }
        if currentChangeCount.map({ $0() == headChangeCount }) ?? true { takeHead() }
        settle()
        return true
    }

    /// Ends the pause after a paste: the next held ⌘V gets its item and is replayed, or the head
    /// goes (back) on the clipboard.
    private func settle() {
        let delay = timing.settle
        pasteTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            pasteTimer = nil
            guard !outgoing.isEmpty else {
                writeHead()
                return
            }
            put(outgoing.removeFirst().itemID)
            replayPaste?()
            settle()
        }
    }

    /// An item was deleted from the library: every entry of it leaves the stack.
    public func itemDeleted(_ itemID: Int64) {
        guard entries.contains(where: { $0.itemID == itemID }) else { return }
        let headBefore = entries.first?.id
        entries.removeAll { $0.itemID == itemID }
        if recentIndex == nil { endRail() }
        if entries.first?.id != headBefore { writeHead() }
        closeIfEmpty()
        changed()
    }

    /// ↵ in the panel's Sıra column pasted this entry out of order: it leaves, and the head
    /// returns to the clipboard once the target has read it.
    public func pastedFromPanel(entryID: Int) {
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            entries.remove(at: index)
            if recentEntryID == entryID { endRail() }
            closeIfEmpty()
            changed()
        }
        let settle = timing.settle
        Task { [weak self] in
            try? await Task.sleep(for: settle)
            self?.writeHead()
        }
    }

    /// The panel pasted something outside the stack; the head goes back on the clipboard.
    public func restoreHead() {
        writeHead()
    }

    /// "Bitir": close and clear.
    public func finish() {
        pasteTimer?.cancel()
        pasteTimer = nil
        outgoing = []
        closeTimer?.cancel()
        endRail()
        entries = []
        isOpen = false
        changed()
    }

    /// The head leaves the stack (its paste is under way); the clipboard is not touched here.
    @discardableResult
    private func takeHead() -> StackEntry {
        let taken = entries.removeFirst()
        if recentIndex == nil { endRail() }
        closeIfEmpty()
        changed()
        return taken
    }

    private func closeIfEmpty() {
        guard entries.isEmpty, isOpen else { return }
        closeTimer?.cancel()
        let delay = timing.closeDelay
        closeTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, entries.isEmpty else { return }
            isOpen = false
            endRail()
            changed()
        }
    }

    private func showRail(for entryID: Int) {
        recentEntryID = entryID
        railTimer?.cancel()
        let duration = timing.rail
        railTimer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            recentEntryID = nil
            changed()
        }
    }

    private func endRail() {
        railTimer?.cancel()
        railTimer = nil
        recentEntryID = nil
    }

    /// Puts the head on the general clipboard with every representation; the monitor is told to
    /// ignore the write so it is not captured as a new copy.
    private func writeHead() {
        guard let head = entries.first, let changeCount = put(head.itemID) else { return }
        headChangeCount = changeCount
    }

    @discardableResult
    private func put(_ itemID: Int64) -> Int? {
        guard let representations = try? library.store.representations(of: itemID), !representations.isEmpty else { return nil }
        let changeCount = writer.write(representations, plainTextOnly: plainText())
        didWrite(changeCount)
        return changeCount
    }

    private func changed() {
        onChange?()
    }
}
