import Foundation
import Observation
import YabExtensionKit

/// Where sources' columns, rows and values come from (`ExtensionService`).
@MainActor public protocol SourceServing: AnyObject {
    /// The usable extensions' sources, in the app's language.
    var sources: [SourceDescriptor] { get }
    /// `key`: a descriptor's id.
    func list(source key: String) async throws(ExtensionError) -> SourceListing
    func run(source key: String, row: String, action: String) async throws(ExtensionError) -> SourceValue
}

/// What the panel shows of each source: the last list it gave, kept in the app's memory and nowhere else (never on
/// disk, in `UserDefaults`, history or a log). The panel opens on the rows already here while a new list is on its way,
/// and the rows go when the Mac locks or sleeps (`clearAll`), when the source says it is locked, and when its extension
/// can no longer run (`sourcesChanged`).
@MainActor @Observable
public final class SourceCenter {
    public enum State: Equatable, Sendable {
        /// Never asked, or forgotten since.
        case idle
        /// Asked, with nothing to show meanwhile.
        case loading
        case rows([SourceRow])
        /// The source is locked: how the person unlocks it, and the line they run for it (⌘C copies it).
        case locked(message: String, command: String?)
        /// The last ask failed and there were no rows to keep: why, in the extension's or the app's words. The column
        /// words it in the person's language from its code; the message is for developers.
        case failed(ExtensionError)
    }

    /// Something a column shows changed: a list came in, or rows were forgotten. Not called by `refresh`, whose caller
    /// reads the states it set right after.
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private let service: SourceServing
    private var states: [String: State] = [:]
    /// The list on its way for each source: one at a time, each with its own number, so a list from before a
    /// `clearAll` (or from a source that went and came back) is let go when it lands.
    @ObservationIgnored private var calls: [String: (id: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var nextCall = 0

    public init(service: SourceServing) {
        self.service = service
    }

    public var descriptors: [SourceDescriptor] { service.sources }

    public func state(of key: String) -> State {
        states[key] ?? .idle
    }

    /// Asks each source for its list again, unless it is already on its way. What is shown (rows, the locked row, a
    /// failure) stays until the answer replaces it, so a source that stays locked never flickers; a source with nothing
    /// shows that it is loading. The call is never cancelled when the panel closes: it fills the next open's rows. A key
    /// no source has is skipped.
    public func refresh(_ keys: [String]) {
        let known = Set(descriptors.map(\.id))
        for key in keys where known.contains(key) && calls[key] == nil {
            if states[key] == nil || states[key] == .idle { states[key] = .loading }
            let id = nextCall
            nextCall += 1
            let service = service
            let task = Task { [weak self] in
                let result: Result<SourceListing, ExtensionError>
                do throws(ExtensionError) {
                    result = .success(try await service.list(source: key))
                } catch {
                    result = .failure(error)
                }
                self?.listed(key, call: id, result)
            }
            calls[key] = (id, task)
        }
    }

    /// A locked source loses its rows at once. A failure keeps the rows shown (a slow or busy source never empties its
    /// column); with none, it shows why.
    private func listed(_ key: String, call id: Int, _ result: Result<SourceListing, ExtensionError>) {
        guard calls[key]?.id == id else { return }
        calls[key] = nil
        let state: State
        switch result {
        case .success(.rows(let rows)): state = .rows(rows)
        case .success(.locked(let message, let command)): state = .locked(message: message, command: command)
        case .failure(let error):
            if case .rows = states[key] { return }
            state = .failed(error)
        }
        guard states[key] != state else { return }
        states[key] = state
        onChange?()
    }

    /// One row action, straight to its extension: the value goes back to the caller and is kept nowhere here.
    public func run(_ key: String, row: String, action: String) async throws(ExtensionError) -> SourceValue {
        try await service.run(source: key, row: row, action: action)
    }

    /// The Mac locked or went to sleep: every row goes, and the lists on their way are stopped (whatever they bring is
    /// let go). The next open asks again.
    public func clearAll() {
        let hadAny = !states.isEmpty
        forget { _ in true }
        if hadAny { onChange?() }
    }

    /// The registry changed: a source no longer offered (its extension removed, turned off or waiting for consent)
    /// loses its rows, and its list on the way is stopped.
    public func sourcesChanged() {
        let known = Set(descriptors.map(\.id))
        let hadGone = states.keys.contains { !known.contains($0) }
        forget { !known.contains($0) }
        if hadGone { onChange?() }
    }

    private func forget(_ isGone: (String) -> Bool) {
        for (key, call) in calls where isGone(key) {
            call.task.cancel()
            calls[key] = nil
        }
        for key in Array(states.keys) where isGone(key) { states[key] = nil }
    }

    /// The list on its way for `key` (tests wait for it to land).
    func call(for key: String) -> Task<Void, Never>? {
        calls[key]?.task
    }
}
