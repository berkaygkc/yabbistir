import Foundation
import Observation
import YabExtensionKit

/// Runs a job's command to its end. In the app this is `ExtensionService`: the jobs' own host,
/// the network and programs allowed, no time limit. Cancelling the calling Task ends the call.
@MainActor
public protocol JobRunning {
    func run(_ command: ExtensionCommand, subjectID: Int64?, target: TargetInfo?,
             progress: @escaping @MainActor (Double?, String?) -> Void) async throws(ExtensionError) -> ExtensionResult
}

/// What a finished job's result meets: the app in front, the panel, the Sıra, history and the clipboard.
@MainActor
public protocol JobEnvironment {
    func frontmostBundleID() -> String?
    var isPanelVisible: Bool { get }
    var isStackOpen: Bool { get }
    /// Adds the result to history; nil when it cannot go there.
    func ingest(_ result: ExtensionResult, from command: ExtensionCommand) -> (itemID: Int64, name: String)?
    /// Pastes the item into the app in front; with the Sıra open, its head goes back on the
    /// clipboard afterwards. False when the paste did not land.
    func paste(_ itemID: Int64) async -> Bool
    func copy(_ itemID: Int64)
    func appendToStack(_ itemID: Int64)
    /// Puts the Sıra's head back on the clipboard at once (a paste that did not go out left the result there).
    func restoreStackHead()
    /// A job failed: a calm notice with its message (the card keeps it too).
    func notifyFailure(_ job: JobCenter.Job)
}

/// Long actions (a download) as jobs. At most `maxConcurrent` run at once
/// and the rest wait their turn; each reports progress, can be cancelled, and delivers its result
/// once, when it ends. A result is pasted only into the app its job was started for, while that
/// app is in front and the panel is closed; otherwise it joins an open Sıra or waits on the
/// clipboard. Finished cards leave after a while; a failed one stays until it is dismissed.
@MainActor @Observable
public final class JobCenter {
    public struct Job: Identifiable, Equatable, Sendable {
        public enum Phase: Sendable, Equatable { case queued, running, done, ready, superseded, failed }
        /// How a `.done` result arrived.
        public enum Delivery: Sendable, Equatable { case pasted, stacked }

        public let id: Int
        public let command: ExtensionCommand
        public let subjectTitle: String
        /// The app the job was started for: the only one its result is pasted into.
        public let target: TargetInfo?
        /// Started with ⌘C: the result goes to the clipboard and is never pasted.
        public let toClipboard: Bool
        public var phase: Phase
        /// Set with `.done` only; a result waiting on the clipboard is `.ready`.
        public var delivery: Delivery?
        /// The share done while the extension can tell; nil while it cannot.
        public var fraction: Double?
        /// The extension's progress line.
        public var message: String?
        /// The file or text the card names when finished.
        public var resultName: String?
        /// Why it failed, in the extension's words.
        public var errorMessage: String?
        /// What failed, when an error was thrown: the card words app-made failures (a missing tool,
        /// a stopped host, a timeout) in the app's language. Nil for `{none, message}` and a result
        /// history refused.
        public var errorCode: ExtensionError.Code?

        public init(id: Int, command: ExtensionCommand, subjectTitle: String, target: TargetInfo?, toClipboard: Bool, phase: Phase,
                    delivery: Delivery? = nil, fraction: Double? = nil, message: String? = nil, resultName: String? = nil,
                    errorMessage: String? = nil, errorCode: ExtensionError.Code? = nil) {
            (self.id, self.command, self.subjectTitle, self.target, self.toClipboard) = (id, command, subjectTitle, target, toClipboard)
            (self.phase, self.delivery, self.fraction, self.message) = (phase, delivery, fraction, message)
            (self.resultName, self.errorMessage, self.errorCode) = (resultName, errorMessage, errorCode)
        }
    }

    /// How long a finished card stays. A failed card stays until it is dismissed; a
    /// cancelled job leaves at once.
    public struct Timing: Sendable {
        public var done: Duration
        public var ready: Duration
        /// A ready card a newer one replaced: its time starts over at this.
        public var superseded: Duration
        /// Calls back once a delay has passed and hands back what cancels that (tests move a clock by hand).
        var schedule: @MainActor @Sendable (_ delay: Duration, _ fire: @escaping @MainActor @Sendable () -> Void)
            -> @MainActor @Sendable () -> Void = Timing.sleeping

        public init(done: Duration, ready: Duration, superseded: Duration) {
            (self.done, self.ready, self.superseded) = (done, ready, superseded)
        }

        public static let standard = Timing(done: .milliseconds(3600), ready: .seconds(9), superseded: .milliseconds(2600))

        private static func sleeping(_ delay: Duration, _ fire: @escaping @MainActor @Sendable () -> Void) -> @MainActor @Sendable () -> Void {
            let task = Task { @MainActor in
                do { try await Task.sleep(for: delay) } catch { return }
                fire()
            }
            return { task.cancel() }
        }
    }

    /// In the order they were started.
    public private(set) var jobs: [Job] = []

    /// Jobs wait or run.
    public var isBusy: Bool { jobs.contains { $0.phase == .queued || $0.phase == .running } }

    /// The mean over running jobs that report a fraction; nil when none can.
    public var aggregateFraction: Double? {
        let known = jobs.filter { $0.phase == .running }.compactMap(\.fraction)
        return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
    }

    @ObservationIgnored private let runner: JobRunning
    @ObservationIgnored private let environment: JobEnvironment
    @ObservationIgnored private let maxConcurrent: Int
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private var lastID = 0
    @ObservationIgnored private var subjectIDs: [Int: Int64] = [:]
    /// The calls in flight. A job leaves this when its call ends, before its result is delivered,
    /// so a cancel never reaches a paste under way.
    @ObservationIgnored private var calls: [Int: Task<Void, Never>] = [:]
    /// Each finished card's countdown; `serial` tells a replaced one from the current one.
    @ObservationIgnored private var countdowns: [Int: (serial: Int, cancel: @MainActor @Sendable () -> Void)] = [:]
    @ObservationIgnored private var lastSerial = 0

    public init(runner: JobRunning, environment: JobEnvironment, maxConcurrent: Int = 3, timing: Timing = .standard) {
        self.runner = runner
        self.environment = environment
        self.maxConcurrent = max(1, maxConcurrent)
        self.timing = timing
    }

    /// `target`: the app the panel opened for, read when the job starts. `toClipboard`: started with ⌘C.
    @discardableResult
    public func start(_ command: ExtensionCommand, subjectID: Int64?, subjectTitle: String, target: TargetInfo?, toClipboard: Bool) -> Int {
        lastID += 1
        let id = lastID
        jobs.append(Job(id: id, command: command, subjectTitle: subjectTitle, target: target, toClipboard: toClipboard, phase: .queued))
        subjectIDs[id] = subjectID
        startWaiting()
        return id
    }

    /// Stops a job and takes its card away at once: a waiting one never runs, a running one's call
    /// is cancelled, and nothing is delivered or added to history. A finished card just closes.
    public func cancel(_ id: Int) {
        guard jobs.contains(where: { $0.id == id }) else { return }
        remove(id)
        startWaiting()
    }

    /// Closes a card (a failed one stays until then); a job still at work is cancelled.
    public func dismiss(_ id: Int) {
        cancel(id)
    }

    /// Stops every waiting or running job whose command matches (its extension can no longer run:
    /// turned off, removed, waiting for consent); finished cards and other jobs stay.
    public func cancelJobs(where matches: (ExtensionCommand) -> Bool) {
        let stopping = jobs.filter { ($0.phase == .queued || $0.phase == .running) && matches($0.command) }
        guard !stopping.isEmpty else { return }
        for job in stopping { remove(job.id) }
        startWaiting()
    }

    /// Stops every job that waits or runs (the app is quitting); finished cards keep their time.
    public func cancelAll() {
        for job in jobs where job.phase == .queued || job.phase == .running { remove(job.id) }
    }

    /// The person copied something else (a capture, never the app's own write): a result that waited
    /// on the clipboard is not there any more, so no ready card promises ⌘V; its time starts over.
    public func clipboardChanged() {
        supersedeReadyCards()
    }

    // MARK: Running

    /// Starts waiting jobs, first come first served, while there is room.
    private func startWaiting() {
        while calls.count < maxConcurrent, let index = jobs.firstIndex(where: { $0.phase == .queued }) {
            jobs[index].phase = .running
            let job = jobs[index], subjectID = subjectIDs[job.id], runner = runner
            calls[job.id] = Task { [weak self] in
                let outcome: Result<ExtensionResult, ExtensionError>
                do throws(ExtensionError) {
                    outcome = .success(try await runner.run(job.command, subjectID: subjectID, target: job.target) { fraction, message in
                        self?.progressed(job.id, fraction: fraction, message: message)
                    })
                } catch {
                    outcome = .failure(error)
                }
                await self?.ended(job.id, outcome)
            }
        }
    }

    private func progressed(_ id: Int, fraction: Double?, message: String?) {
        guard let index = index(of: id, in: .running) else { return }
        jobs[index].fraction = fraction
        jobs[index].message = message
    }

    /// The job's call ended (on its own Task): its place goes to the next in line, then its result is delivered.
    private func ended(_ id: Int, _ outcome: Result<ExtensionResult, ExtensionError>) async {
        calls[id] = nil
        startWaiting()
        // Cancelled or dismissed meanwhile: it has already left, with nothing delivered.
        guard let index = index(of: id, in: .running) else { return }
        guard !Task.isCancelled else { return remove(id) }
        switch outcome {
        case .failure(let error) where error.code == .cancelled:
            remove(id)
        case .failure(let error):
            fail(id, message: error.message, code: error.code)
        case .success(.none(let message)):
            // Nothing for history either way.
            if let message { fail(id, message: message) } else { remove(id) }
        case .success(let result):
            await deliver(result, of: jobs[index])
        }
    }

    /// Into history always; pasted only into the job's own target while it is in front
    /// and the panel is closed (never for ⌘C); otherwise onto the open Sıra, or the clipboard.
    private func deliver(_ result: ExtensionResult, of job: Job) async {
        guard let ingested = environment.ingest(result, from: job.command) else { return fail(job.id, message: nil) }
        let (itemID, name) = ingested
        if !job.toClipboard, let target = job.target, environment.frontmostBundleID() == target.bundleID, !environment.isPanelVisible {
            let pasted = await environment.paste(itemID)
            // The paster put the result on the clipboard before it found it could not paste: an open
            // Sıra gets its head back there, also when the card was closed meanwhile.
            if !pasted, environment.isStackOpen { environment.restoreStackHead() }
            // Cancelled or dismissed while it pasted: the card is gone and stays gone.
            guard index(of: job.id, in: .running) != nil else { return }
            if pasted { return finish(job.id, delivery: .pasted, resultName: name) }
        }
        if environment.isStackOpen {
            environment.appendToStack(itemID)
            finish(job.id, delivery: .stacked, resultName: name)
        } else {
            environment.copy(itemID)
            becomeReady(job.id, resultName: name)
        }
    }

    private func finish(_ id: Int, delivery: Job.Delivery, resultName: String) {
        guard let index = index(of: id, in: .running) else { return }
        // A paste leaves its item on the clipboard; joining the Sıra leaves the clipboard alone.
        if delivery == .pasted { supersedeReadyCards() }
        jobs[index].phase = .done
        jobs[index].delivery = delivery
        jobs[index].resultName = resultName
        countDown(id, timing.done)
    }

    private func becomeReady(_ id: Int, resultName: String) {
        guard let index = index(of: id, in: .running) else { return }
        supersedeReadyCards()
        jobs[index].phase = .ready
        jobs[index].resultName = resultName
        countDown(id, timing.ready)
    }

    /// Only the newest result on the clipboard promises ⌘V: once another takes its place, an
    /// older ready card becomes superseded, and its time starts over.
    private func supersedeReadyCards() {
        for older in jobs.indices where jobs[older].phase == .ready {
            jobs[older].phase = .superseded
            countDown(jobs[older].id, timing.superseded)
        }
    }

    private func fail(_ id: Int, message: String?, code: ExtensionError.Code? = nil) {
        guard let index = index(of: id, in: .running) else { return }
        jobs[index].phase = .failed
        jobs[index].errorMessage = message
        jobs[index].errorCode = code
        environment.notifyFailure(jobs[index])
    }

    // MARK: Cards

    private func countDown(_ id: Int, _ delay: Duration) {
        countdowns[id]?.cancel()
        lastSerial += 1
        let serial = lastSerial
        let cancel = timing.schedule(delay) { [weak self] in self?.countedDown(id, serial: serial) }
        countdowns[id] = (serial, cancel)
    }

    private func countedDown(_ id: Int, serial: Int) {
        // A countdown since replaced, or one whose card already left, removes nothing.
        guard countdowns[id]?.serial == serial else { return }
        remove(id)
    }

    /// The card leaves now, with its countdown, and its call if it still has one.
    private func remove(_ id: Int) {
        countdowns.removeValue(forKey: id)?.cancel()
        calls.removeValue(forKey: id)?.cancel()
        subjectIDs[id] = nil
        jobs.removeAll { $0.id == id }
    }

    private func index(of id: Int, in phase: Job.Phase) -> Int? {
        jobs.firstIndex { $0.id == id && $0.phase == phase }
    }
}
