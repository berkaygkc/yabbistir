import Foundation
import Synchronization
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
///
/// A call's clock goes by when things happened, never by when the main actor gets to them: it starts as the
/// request is sent, runs on a plain timer, pauses from the moment a request to the app comes in, and an answer
/// or a cancel is judged by when it came. Everything from other threads (the host's lines, its exit, a caller
/// giving up, a clock running out) reaches the main actor through one inbox, in the order it happened.
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
    /// What other threads hand the main actor, in the order it happened.
    private let inbox = Inbox()
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
                    // Timed as it comes in, and decoded on the reading thread: a big answer never costs the main actor.
                    let arrived = ContinuousClock.now
                    guard let message = try? JSONDecoder().decode(HostMessage.self, from: line) else { return }
                    self?.post(.line(message, arrived: arrived))
                }, onExit: { [weak self] in
                    self?.post(.exited)
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
        } onCancel: { [weak self] in
            self?.post(.cancelled(id: id, at: .now))
        }
        return message
    }

    /// Puts `event` in the inbox, from any thread; the main actor then takes everything there, in order.
    nonisolated private func post(_ event: Inbox.Event) {
        inbox.post(event)
        Task { @MainActor [weak self] in self?.drain() }
    }

    /// Takes what came from other threads, in the order it happened, whichever hop brought the main actor here.
    private func drain() {
        for event in inbox.take() {
            switch event {
            case .line(let message, let arrived): receive(message, arrived: arrived)
            case .exited: hostExited()
            case .cancelled(let id, let at): cancel(id, at: at)
            case .clock(let id, let turn): clockWentOff(id, turn: turn)
            }
        }
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

    /// Runs a call's clock down from what it has left, from now; out of time, the call times out. A pause it was in
    /// ends, and what it took comes off the call's pause budget (all of it when `pauseSpent`).
    private func runClock(_ id: Int, pauseSpent: Bool = false) {
        guard var clock = clocks[id], clock.since == nil else { return }
        clock.timer?.cancel()
        let now = ContinuousClock.now
        if let paused = clock.pausedSince {
            clock.pauseLeft = pauseSpent ? .zero : max(.zero, clock.pauseLeft - (now - paused))
            clock.pausedSince = nil
        }
        clock.since = now
        startTimer(id, &clock, after: clock.remaining)
        clocks[id] = clock
    }

    /// Pauses a call's clock from `arrived`, when its request to the app came in (the main actor's wait to take it up
    /// is the app's time too), keeping what it has left, for at most what is left of its pause budget: then it runs
    /// again whatever the app is still doing for it. With the budget spent it does not pause.
    private func pauseClock(_ id: Int, from arrived: ContinuousClock.Instant) {
        guard var clock = clocks[id], let since = clock.since, clock.pauseLeft > .zero else { return }
        clock.timer?.cancel()
        // Never from before the clock last started: a request that came in while it was paused, taken up after.
        let paused = max(arrived, since)
        clock.remaining -= paused - since
        clock.since = nil
        clock.pausedSince = paused
        startTimer(id, &clock, after: clock.pauseLeft - (ContinuousClock.now - paused))
        clocks[id] = clock
    }

    /// A plain timer for the clock's next turn, off the main actor and the task pool: it goes off on time however busy
    /// they are, and its event joins the inbox behind whatever came in before it.
    private func startTimer(_ id: Int, _ clock: inout CallClock, after delay: Duration) {
        clock.turn += 1
        clock.timer = arm(.clock(id: id, turn: clock.turn), after: delay)
    }

    /// Posts `event` after `delay`. Nonisolated: the timer's block runs on a global queue.
    nonisolated private func arm(_ event: Inbox.Event, after delay: Duration) -> DispatchWorkItem {
        let timer = DispatchWorkItem { [weak self] in self?.post(event) }
        let (seconds, attoseconds) = max(.zero, delay).components
        let interval = DispatchTimeInterval.nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval, execute: timer)
        return timer
    }

    /// A clock's timer went off: running, the call is out of time; paused, its pause budget is spent and it runs
    /// again. One from an earlier turn (the clock paused or ran again since) or for a call that ended is let go.
    private func clockWentOff(_ id: Int, turn: Int) {
        guard let clock = clocks[id], clock.turn == turn else { return }
        if clock.since != nil { timedOut(id) } else { runClock(id, pauseSpent: true) }
    }

    /// Whether a call's clock was running at `instant` and its time was up by then.
    private func isOutOfTime(_ id: Int, at instant: ContinuousClock.Instant) -> Bool {
        guard let clock = clocks[id], let since = clock.since else { return false }
        return instant - since >= clock.remaining
    }

    private func answer(_ id: Int, _ error: ExtensionError) {
        take(id)?.resume(returning: HostMessage(id: id, error: error))
    }

    /// The caller's Task was cancelled (`at`): the call fails with `cancelled` now and the host is told to
    /// abort it; whatever it answers later finds nobody waiting. No restart, no blame, unless the call's own time
    /// was up by then: that is a timeout, whether its timer or the cancel reached the main actor first.
    private func cancel(_ id: Int, at: ContinuousClock.Instant) {
        if isOutOfTime(id, at: at) { timedOut(id); return }
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

    /// A line from the host, which came in at `arrived`.
    private func receive(_ message: HostMessage, arrived: ContinuousClock.Instant) {
        switch message.event {
        case "log":
            if let extensionID = message.extensionID { onLog(extensionID, message.message ?? "") }
            return
        case "progress":
            // Never an answer: the call goes on.
            if let id = message.id { progressHandlers[id]?(message.fraction, message.message) }
            return
        case "call":
            ask(message, arrived: arrived)
            return
        case nil:
            break
        default:
            return
        }
        guard let id = message.id else { return }
        // An answer that came after the call's time was up is no answer, even when its timer is late.
        if isOutOfTime(id, at: arrived) { timedOut(id); return }
        guard let continuation = take(id) else { return }
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
    private func ask(_ message: HostMessage, arrived: ContinuousClock.Instant) {
        guard let invokeID = message.id, let invoke = invokes[invokeID], let requestID = message.requestID,
              let method = message.method else { return }
        // Asked after the call's time was up: it is out of time, not waiting for the app.
        if isOutOfTime(invokeID, at: arrived) { timedOut(invokeID); return }
        let call = HostCall(extensionID: invoke.extensionID, invokeID: invokeID, requestID: requestID, kind: invoke.kind,
                            method: method, params: message.params ?? .null, effects: invoke.effects)
        let handler = onHostCall
        // The app is at work for a run the person started: its clock waits (within its pause budget), and goes on
        // once the app has answered everything it asked. Hints, detectors, previews and rules keep their clock running.
        if invoke.effects, invoke.requests.isEmpty { pauseClock(invokeID, from: arrived) }
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
    var timer: DispatchWorkItem?
    /// Counts the timer's starts: one that goes off for an earlier turn is let go.
    var turn = 0

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

/// What other threads hand the client, kept in the order it happened: the host's lines (with when each came in),
/// the host stopping, a caller giving up, a clock running out. The main actor takes them in that order, whatever
/// order it runs the hops that bring it here.
private final class Inbox: Sendable {
    enum Event: Sendable {
        case line(HostMessage, arrived: ContinuousClock.Instant)
        case exited
        case cancelled(id: Int, at: ContinuousClock.Instant)
        case clock(id: Int, turn: Int)
    }

    private let events = Mutex<[Event]>([])

    func post(_ event: Event) {
        events.withLock { $0.append(event) }
    }

    /// Everything posted so far, oldest first; the inbox is empty after.
    func take() -> [Event] {
        events.withLock { events in
            defer { events = [] }
            return events
        }
    }
}
