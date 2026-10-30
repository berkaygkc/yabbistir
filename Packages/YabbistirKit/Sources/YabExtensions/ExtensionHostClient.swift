import Foundation
import YabExtensionKit

/// The app's side of the extension host: numbered requests, answers matched by id, a time limit
/// on every call but a job's. A call that runs out of time restarts the host; an extension that
/// fails three times in a row (its own calls and loads, never the ones another call's restart cut
/// short, the person cancelled, or that only report the world: a missing tool, the network, a
/// refused permission; and for a job only when the extension is broken) is turned off. Cancelling the calling
/// Task ends the call at once and tells the host to abort it. JSON is encoded and decoded off the
/// main actor, and writes never wait for the host, so a big item costs the app nothing while it travels.
///
/// A call can ask the app for something while it runs (`onHostCall`): each request is a Task of its
/// own that ends with the call, however the call ends. A run the person started (`effects`) has its
/// clock stop while the app works on its requests (a translation, the on-device model): that time is the
/// app's, not the extension's. It stops for `pauseLimit` at most in all; past that it runs whatever is
/// still asked. Hints, detectors, previews and rules never stop theirs.
@MainActor
public final class ExtensionHostClient {
    public static let failureLimit = 3
    /// A load (running index.js's top level) gets this long.
    let loadTimeout: Duration
    /// The longest a call's clock waits for the app, in all (the router's limit for one request, by default).
    let pauseLimit: Duration

    /// An extension was turned off after `failureLimit` failures in a row.
    public var onExtensionDisabled: ((String) -> Void)?
    /// The host started over (a call ran out of time) or stopped on its own (`exited`): nothing is loaded in it any
    /// more, and what was on its way to it has failed. Called after that, once per restart or stop.
    public var onHostRestarted: ((_ exited: Bool) -> Void)?
    /// Answers a running call's request to the app (`HostCallRouter.handle`); without it every request fails.
    public var onHostCall: (@MainActor (HostCall) async throws(ExtensionError) -> JSONValue)?

    private let transport: HostTransport
    private let onLog: (String, String) -> Void
    private var started = false
    /// The host stopped on its own: the next call starts a fresh one.
    private var needsRestart = false
    /// Encodes and hands requests to the transport in order (a load before its invoke).
    private let encoder = DispatchQueue(label: "dev.yabbistir.extension-host.encoder")
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<HostMessage, Never>] = [:]
    /// Where each call's progress events go, beside its continuation in `pending`.
    private var progressHandlers: [Int: (_ fraction: Double?, _ message: String?) -> Void] = [:]
    /// Each invoke in flight, beside its continuation in `pending`: who it is and what it may do, as it
    /// was sent (a request is judged by that, never by what the host says), and its open requests to the app.
    private var invokes: [Int: InvokeInFlight] = [:]
    /// Each timed call's clock, beside its continuation in `pending`.
    private var clocks: [Int: CallClock] = [:]
    /// What to load again after a restart.
    private var loads: [String: LoadRequest] = [:]
    private var loadedInHost: Set<String> = []
    private var failures: [String: Int] = [:]
    private var disabled: Set<String> = []

    /// `pauseLimit`: the longest a call's clock waits for the app, in all (tests make it short).
    public init(transport: HostTransport, loadTimeout: Duration = .seconds(5), pauseLimit: Duration = HostCallRouter.serviceLimit,
                onLog: @escaping (String, String) -> Void) {
        self.transport = transport
        self.loadTimeout = loadTimeout
        self.pauseLimit = pauseLimit
        self.onLog = onLog
    }

    public func isDisabled(_ id: String) -> Bool { disabled.contains(id) }

    /// A line for Settings → Development, under the extension, from the app's side. Never user content.
    public func log(_ id: String, _ line: String) {
        onLog(id, line)
    }

    /// Gives a turned-off extension another chance (the user turned it back on).
    public func reset(_ id: String) {
        disabled.remove(id)
        failures[id] = 0
    }

    /// Every extension starts over: their files or switches changed.
    public func resetAll() {
        disabled = []
        failures = [:]
    }

    /// `grant`: what the extension may use; `toolSearchPath`: where its tools are looked for;
    /// `secrets`: its own secret preferences (kept for a reload, never logged).
    public func load(_ id: String, folder: URL, dataFolder: URL, language: String, grant: PermissionGrant = .empty,
                     toolSearchPath: [String] = [], secrets: [String: String] = [:]) async throws(ExtensionError) {
        guard !disabled.contains(id) else { throw ExtensionError(.unavailable, "\(id) was turned off after repeated errors") }
        let request = LoadRequest(extensionID: id, folder: folder.path, dataFolder: dataFolder.path, language: language,
                                  grant: grant, toolSearchPath: toolSearchPath, secrets: secrets)
        loads[id] = request
        try await load(request)
    }

    public func unload(_ id: String) {
        loads[id] = nil
        guard loadedInHost.remove(id) != nil else { return }
        Task { _ = try? await send(HostRequest(unload: UnloadRequest(extensionID: id)), timeout: loadTimeout) }
    }

    /// `effects`: the network and programs are allowed (only a run the person started).
    /// `timeout`: nil for none (a job). `onProgress` hears `yab.job.progress` until the call ends.
    public func invoke(_ id: String, _ kind: InvokeKind, name: String, item: ExtensionItem?, context: ExtensionContext,
                       effects: Bool = false, timeout: Duration?,
                       onProgress: ((_ fraction: Double?, _ message: String?) -> Void)? = nil) async throws(ExtensionError) -> InvokeOutput {
        guard !disabled.contains(id) else { throw ExtensionError(.unavailable, "\(id) was turned off after repeated errors") }
        // A failed load counts once, in load().
        if !loadedInHost.contains(id), let request = loads[id] { try await load(request) }
        do throws(ExtensionError) {
            let request = InvokeRequest(extensionID: id, kind: kind, name: name, item: item, context: context, effects: effects)
            let message = try await send(HostRequest(invoke: request), timeout: timeout, onProgress: onProgress)
            if let error = message.error { throw error }
            guard let output = message.ok else { throw ExtensionError(.badResult, "the host answered without a result") }
            failures[id] = 0
            return output
        } catch {
            // What it returned is not a result: the app's reason, in English, is for the developer (never
            // user content: it names shapes, not values). The card and notices word it themselves.
            if error.code == .badResult { onLog(id, "\(name) returned no result: \(error.message)") }
            // A job (no time limit) reports its failures with a message: only a broken extension counts.
            if timeout == nil ? Self.isBroken(error) : !Self.isNobodysFault(error) { recordFailure(id) }
            throw error
        }
    }

    /// Not the extension's failure: cut short by another call's restart or the host stopping, cancelled
    /// by the person, or a failure it reports about the world (a missing tool, the network, a
    /// permission it was refused). The host turns off an extension that crashes, not one that says why.
    private static func isNobodysFault(_ error: ExtensionError) -> Bool {
        [.interrupted, .cancelled, .toolMissing, .networkError, .permissionDenied].contains(error.code)
    }

    /// A job's failure that means the extension is broken: what it returned is not a result, or what
    /// was called is not there. A `script` error it threw is a failure it reported, with its message.
    /// (A load that fails or hangs the host counts in `load`, for jobs too.)
    private static func isBroken(_ error: ExtensionError) -> Bool {
        [.badResult, .notFound, .syntax].contains(error.code)
    }

    // MARK: Plumbing

    private func load(_ request: LoadRequest) async throws(ExtensionError) {
        do throws(ExtensionError) {
            let message = try await send(HostRequest(load: request), timeout: loadTimeout)
            if let error = message.error { throw error }
            loadedInHost.insert(request.extensionID)
        } catch {
            if !Self.isNobodysFault(error) {
                // Settings → Development shows why: a throwing or endless top level, a bad file.
                onLog(request.extensionID, "index.js could not load: \(error.message)")
                recordFailure(request.extensionID)
            }
            throw error
        }
    }

    private func send(_ request: HostRequest, timeout: Duration?,
                      onProgress: ((_ fraction: Double?, _ message: String?) -> Void)? = nil) async throws(ExtensionError) -> HostMessage {
        guard !Task.isCancelled else { throw ExtensionError(.cancelled, "the call was cancelled") }
        do {
            if !started {
                try transport.start(onLine: { [weak self] line in
                    // Decoded on the reading thread: a big answer never costs the main actor.
                    guard let message = try? JSONDecoder().decode(HostMessage.self, from: line) else { return }
                    Task { @MainActor in self?.receive(message) }
                }, onExit: { [weak self] in
                    Task { @MainActor in self?.hostExited() }
                })
                started = true
            } else if needsRestart {
                try transport.restart()
                needsRestart = false
            }
        } catch {
            throw ExtensionError(.unavailable, "the extension host could not start: \(error.localizedDescription)")
        }
        var request = request
        request.id = nextID
        nextID += 1
        let id = request.id
        let transport = transport
        let message = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<HostMessage, Never>) in
                pending[id] = continuation
                progressHandlers[id] = onProgress
                if let invoke = request.invoke {
                    invokes[id] = InvokeInFlight(extensionID: invoke.extensionID, kind: invoke.kind, effects: invoke.effects)
                }
                // The clock starts now, not when the bytes have left.
                if let timeout {
                    clocks[id] = CallClock(remaining: timeout, pauseLeft: pauseLimit)
                    runClock(id)
                }
                encoder.async { [weak self] in
                    guard let data = try? JSONEncoder().encode(request) else {
                        Task { @MainActor in self?.answer(id, ExtensionError(.badResult, "the request could not be encoded")) }
                        return
                    }
                    transport.send(data)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        return message
    }

    /// The call is over for the caller: its continuation, if it was still waiting, no more progress, its
    /// clock stops, and its requests to the app stop.
    private func take(_ id: Int) -> CheckedContinuation<HostMessage, Never>? {
        progressHandlers[id] = nil
        clocks.removeValue(forKey: id)?.timer?.cancel()
        invokes.removeValue(forKey: id)?.requests.values.forEach { $0.cancel() }
        return pending.removeValue(forKey: id)
    }

    /// Everything in flight is over (the host stopped or restarted): every clock and every request to the app stops.
    private func endAllInvokes() {
        let (all, timed) = (invokes, clocks)
        (invokes, clocks) = ([:], [:])
        for clock in timed.values { clock.timer?.cancel() }
        for invoke in all.values { invoke.requests.values.forEach { $0.cancel() } }
    }

    // MARK: Clocks

    /// Runs a call's clock down from what it has left; out of time, the call times out. A pause it was in ends,
    /// and what it took comes off the call's pause budget (all of it when `pauseSpent`).
    private func runClock(_ id: Int, pauseSpent: Bool = false) {
        guard var clock = clocks[id], clock.since == nil else { return }
        clock.timer?.cancel()
        if let paused = clock.pausedSince {
            clock.pauseLeft = pauseSpent ? .zero : max(.zero, clock.pauseLeft - (ContinuousClock.now - paused))
            clock.pausedSince = nil
        }
        let remaining = clock.remaining
        clock.since = .now
        clock.timer = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            // Paused or stopped meanwhile (on this actor, before this turn): its time is not up.
            guard !Task.isCancelled else { return }
            self?.timedOut(id)
        }
        clocks[id] = clock
    }

    /// Pauses a call's clock, keeping what it has left, for at most what is left of its pause budget: then it runs
    /// again whatever the app is still doing for it. With the budget spent it does not pause.
    private func pauseClock(_ id: Int) {
        guard var clock = clocks[id], let since = clock.since, clock.pauseLeft > .zero else { return }
        clock.timer?.cancel()
        clock.remaining -= ContinuousClock.now - since
        clock.since = nil
        clock.pausedSince = .now
        let pauseLeft = clock.pauseLeft
        clock.timer = Task { [weak self] in
            try? await Task.sleep(for: pauseLeft)
            // Ran again meanwhile: the pause is over already.
            guard !Task.isCancelled else { return }
            self?.runClock(id, pauseSpent: true)
        }
        clocks[id] = clock
    }

    private func answer(_ id: Int, _ error: ExtensionError) {
        take(id)?.resume(returning: HostMessage(id: id, error: error))
    }

    /// The caller's Task was cancelled: the call fails with `cancelled` now and the host is told to
    /// abort it; whatever it answers later finds nobody waiting. No restart, no blame.
    private func cancel(_ id: Int) {
        guard let continuation = take(id) else { return }
        let transport = transport
        encoder.async {
            guard let data = try? JSONEncoder().encode(HostRequest(cancel: CancelRequest(callID: id))) else { return }
            transport.send(data)
        }
        continuation.resume(returning: HostMessage(id: id, error: ExtensionError(.cancelled, "the call was cancelled")))
    }

    /// The host quit or crashed: what was in flight fails at once (nobody's fault) and the next
    /// call starts a fresh host.
    private func hostExited() {
        needsRestart = true
        loadedInHost = []
        let all = pending
        pending = [:]
        progressHandlers = [:]
        endAllInvokes()
        for (id, continuation) in all {
            continuation.resume(returning: HostMessage(id: id, error: ExtensionError(.interrupted, "the extension host stopped")))
        }
        onHostRestarted?(true)
    }

    private func receive(_ message: HostMessage) {
        switch message.event {
        case "log":
            if let extensionID = message.extensionID { onLog(extensionID, message.message ?? "") }
            return
        case "progress":
            // Never an answer: the call goes on.
            if let id = message.id { progressHandlers[id]?(message.fraction, message.message) }
            return
        case "call":
            ask(message)
            return
        case nil:
            break
        default:
            return
        }
        guard let id = message.id, let continuation = take(id) else { return }
        continuation.resume(returning: message)
    }

    /// The call ran out of time: it fails, the host restarts, and everything else in flight fails
    /// with "restarted" (their extensions load again on next use).
    private func timedOut(_ id: Int) {
        guard let continuation = take(id) else { return }
        continuation.resume(returning: HostMessage(id: id, error: ExtensionError(.timeout, "the extension did not answer in time")))
        try? transport.restart()
        loadedInHost = []
        let others = pending
        pending = [:]
        progressHandlers = [:]
        endAllInvokes()
        for (otherID, other) in others {
            other.resume(returning: HostMessage(id: otherID, error: ExtensionError(.interrupted, "the extension host restarted")))
        }
        onHostRestarted?(false)
    }

    // MARK: Requests to the app

    /// A running call asks the app for something: answered by `onHostCall` in a Task of its own, which
    /// stops when the call ends. A request from a call that is no longer in flight is not taken up.
    private func ask(_ message: HostMessage) {
        guard let invokeID = message.id, let invoke = invokes[invokeID], let requestID = message.requestID,
              let method = message.method else { return }
        let call = HostCall(extensionID: invoke.extensionID, invokeID: invokeID, requestID: requestID, kind: invoke.kind,
                            method: method, params: message.params ?? .null, effects: invoke.effects)
        let handler = onHostCall
        // The app is at work for a run the person started: its clock waits (within its pause budget), and goes on
        // once the app has answered everything it asked. Hints, detectors, previews and rules keep their clock running.
        if invoke.effects, invoke.requests.isEmpty { pauseClock(invokeID) }
        invokes[invokeID]?.requests[requestID] = Task { [weak self] in
            let outcome: Result<JSONValue, ExtensionError>
            if let handler {
                do throws(ExtensionError) { outcome = .success(try await handler(call)) } catch { outcome = .failure(error) }
            } else {
                outcome = .failure(ExtensionError(.unavailable, "the app takes no requests"))
            }
            self?.reply(to: call, outcome)
        }
    }

    /// The answer goes to the host behind whatever is already on its way. Not once the call has ended:
    /// the host already rejected the request, and a host started since could be waiting on the same number.
    private func reply(to call: HostCall, _ outcome: Result<JSONValue, ExtensionError>) {
        guard invokes[call.invokeID]?.requests.removeValue(forKey: call.requestID) != nil else { return }
        if invokes[call.invokeID]?.requests.isEmpty == true { runClock(call.invokeID) }
        let reply = switch outcome {
        case .success(let value): ReplyRequest(requestID: call.requestID, ok: value)
        case .failure(let error): ReplyRequest(requestID: call.requestID, error: error)
        }
        let transport = transport
        encoder.async {
            let unencodable = ReplyRequest(requestID: reply.requestID, error: ExtensionError(.badResult, "the app's answer could not be encoded"))
            guard let data = (try? JSONEncoder().encode(HostRequest(reply: reply))) ?? (try? JSONEncoder().encode(HostRequest(reply: unencodable)))
            else { return }
            transport.send(data)
        }
    }

    private func recordFailure(_ id: String) {
        let count = (failures[id] ?? 0) + 1
        failures[id] = count
        if count >= Self.failureLimit, disabled.insert(id).inserted { onExtensionDisabled?(id) }
    }
}

/// How much time a call has left, and the timer running it down; while the app answers its requests, the timer
/// runs down its pause budget instead.
private struct CallClock {
    var remaining: Duration
    /// How much longer the call may wait for the app, in all.
    var pauseLeft: Duration
    /// When the timer started from `remaining`; nil while paused.
    var since: ContinuousClock.Instant?
    /// When the pause in progress began.
    var pausedSince: ContinuousClock.Instant?
    var timer: Task<Void, Never>?

    init(remaining: Duration, pauseLeft: Duration) {
        (self.remaining, self.pauseLeft) = (remaining, pauseLeft)
    }
}

/// An invoke in flight, as it was sent, and the Tasks answering its requests to the app (by request number).
private struct InvokeInFlight {
    let extensionID: String
    let kind: InvokeKind
    let effects: Bool
    var requests: [Int: Task<Void, Never>] = [:]
}
