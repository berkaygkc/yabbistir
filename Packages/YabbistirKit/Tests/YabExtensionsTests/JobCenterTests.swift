import Foundation
import Testing
import YabExtensionKit
@testable import YabExtensions

/// A runner whose jobs end when the test says so. A cancelled call ends with `cancelled` at once,
/// as the host client's does, unless `ignoresCancel` keeps it going until the test answers.
@MainActor final class FakeRunner: JobRunning {
    struct Call {
        let command: ExtensionCommand
        let subjectID: Int64?
        let target: TargetInfo?
        let progress: @MainActor (Double?, String?) -> Void
    }

    private(set) var calls: [Call] = []
    /// Calls that saw their Task cancelled when they ended.
    private(set) var cancelled: Set<Int> = []
    var ignoresCancel = false
    private var answers: [Int: CheckedContinuation<Result<ExtensionResult, ExtensionError>, Never>] = [:]

    func run(_ command: ExtensionCommand, subjectID: Int64?, target: TargetInfo?,
             progress: @escaping @MainActor (Double?, String?) -> Void) async throws(ExtensionError) -> ExtensionResult {
        let index = calls.count
        calls.append(Call(command: command, subjectID: subjectID, target: target, progress: progress))
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { answers[index] = $0 }
        } onCancel: {
            Task { @MainActor in
                guard !self.ignoresCancel else { return }
                self.answer(index, .failure(ExtensionError(.cancelled, "the call was cancelled")))
            }
        }
        if Task.isCancelled { cancelled.insert(index) }
        return try outcome.get()
    }

    func finish(_ index: Int, _ result: ExtensionResult) { answer(index, .success(result)) }
    func fail(_ index: Int, _ error: ExtensionError) { answer(index, .failure(error)) }

    private func answer(_ index: Int, _ outcome: Result<ExtensionResult, ExtensionError>) {
        answers.removeValue(forKey: index)?.resume(returning: outcome)
    }
}

/// The app around the jobs: who is in front, the panel, the Sıra, and what happened to results.
@MainActor final class FakeJobEnvironment: JobEnvironment {
    var frontmost: String?
    var isPanelVisible = false
    var isStackOpen = false
    var pasteLands = true
    /// History refuses the result.
    var ingestFails = false
    private(set) var ingested: [ExtensionResult] = []
    private(set) var pasted: [Int64] = []
    private(set) var copied: [Int64] = []
    private(set) var stacked: [Int64] = []
    private(set) var failures: [JobCenter.Job] = []
    private var lastItemID: Int64 = 100

    func frontmostBundleID() -> String? { frontmost }

    func ingest(_ result: ExtensionResult, from command: ExtensionCommand) -> (itemID: Int64, name: String)? {
        guard !ingestFails else { return nil }
        ingested.append(result)
        lastItemID += 1
        let name = switch result {
        case .files(let paths): URL(fileURLWithPath: paths[0]).lastPathComponent
        case .text(let text): text
        default: "result"
        }
        return (lastItemID, name)
    }

    /// What the clipboard holds, as the app's pieces leave it: the paster writes the result before it
    /// checks anything, joining the Sıra (and restoring it) puts its head back, a copy puts the item.
    private(set) var clipboard: Int64?
    /// The Sıra's head before any result joins it.
    var stackHead: Int64?
    /// The next paste waits until `releasePaste()`.
    var holdsPaste = false
    private var heldPaste: CheckedContinuation<Void, Never>?
    var isPasting: Bool { heldPaste != nil }

    func paste(_ itemID: Int64) async -> Bool {
        pasted.append(itemID)
        clipboard = itemID
        if holdsPaste { await withCheckedContinuation { heldPaste = $0 } }
        return pasteLands
    }

    func releasePaste() {
        heldPaste?.resume()
        heldPaste = nil
    }

    func copy(_ itemID: Int64) {
        copied.append(itemID)
        clipboard = itemID
    }

    func appendToStack(_ itemID: Int64) {
        stacked.append(itemID)
        stackHead = stackHead ?? itemID
        clipboard = stackHead
    }

    func restoreStackHead() { clipboard = stackHead }
    func notifyFailure(_ job: JobCenter.Job) { failures.append(job) }
}

/// Time the test moves by hand: a countdown fires, in deadline order, when `advance` passes it.
@MainActor final class ManualClock {
    private var now: Duration = .zero
    private var countdowns: [(id: Int, deadline: Duration, fire: @MainActor @Sendable () -> Void)] = []
    private var lastID = 0

    func schedule(_ delay: Duration, _ fire: @escaping @MainActor @Sendable () -> Void) -> @MainActor @Sendable () -> Void {
        lastID += 1
        let id = lastID
        countdowns.append((id, now + delay, fire))
        return { [weak self] in self?.countdowns.removeAll { $0.id == id } }
    }

    func advance(by duration: Duration) {
        now += duration
        while let next = countdowns.filter({ $0.deadline <= now }).min(by: { $0.deadline < $1.deadline }) {
            countdowns.removeAll { $0.id == next.id }
            next.fire()
        }
    }
}

extension JobCenter.Timing {
    /// The real durations, on a clock the test moves.
    static func driven(by clock: ManualClock) -> Self {
        var timing = Self.standard
        timing.schedule = { delay, fire in clock.schedule(delay, fire) }
        return timing
    }
}

@MainActor @Suite struct JobCenterTests {
    let runner = FakeRunner()
    let environment = FakeJobEnvironment()
    let clock = ManualClock()

    static let finder = TargetInfo(bundleID: "com.apple.finder", name: "Finder", kind: .finder)
    static let video = ExtensionCommand(id: "dev.yabbistir.video-download/video", extensionID: "dev.yabbistir.video-download",
                                        extensionName: "Video İndir", icon: "sf:arrow.down.circle", title: "Video olarak indir",
                                        subtitle: nil, keywords: [], input: .item, output: .file, hint: false, priority: 0,
                                        actionID: "video", variant: nil, source: .development, accepts: nil, targets: [.finder],
                                        isJob: true, verb: "İndir")
    static let download = ExtensionResult.files(paths: ["/Outputs/1/SwiftUI ile Liquid Glass.mp4"])

    func center(maxConcurrent: Int = 3) -> JobCenter {
        JobCenter(runner: runner, environment: environment, maxConcurrent: maxConcurrent, timing: .driven(by: clock))
    }

    @discardableResult
    func start(_ center: JobCenter, target: TargetInfo? = finder, toClipboard: Bool = false) -> Int {
        center.start(Self.video, subjectID: 7, subjectTitle: "SwiftUI ile Liquid Glass", target: target, toClipboard: toClipboard)
    }

    func job(_ id: Int, in center: JobCenter) -> JobCenter.Job? { center.jobs.first { $0.id == id } }

    // MARK: Queue

    @Test func threeRunAndTheFourthWaits() async throws {
        let center = center()
        let ids = (0..<5).map { _ in start(center) }
        try await eventually { runner.calls.count == 3 }
        #expect(center.jobs.map(\.id) == ids)
        #expect(center.jobs.map(\.phase) == [.running, .running, .running, .queued, .queued])
        #expect(center.isBusy)
        #expect(runner.calls.allSatisfy { $0.command == Self.video && $0.subjectID == 7 && $0.target == Self.finder })

        // The first in line takes the free place; the last keeps waiting.
        runner.finish(1, Self.download)
        try await eventually { runner.calls.count == 4 }
        #expect(job(ids[3], in: center)?.phase == .running)
        #expect(job(ids[4], in: center)?.phase == .queued)
        #expect(center.jobs.filter { $0.phase == .running }.count == 3)
    }

    @Test func cancellingAQueuedJobNeverRunsIt() async throws {
        let center = center(maxConcurrent: 1)
        start(center)
        let queued = start(center)
        try await eventually { runner.calls.count == 1 }
        center.cancel(queued)
        #expect(center.jobs.count == 1)
        runner.finish(0, Self.download)
        try await eventually { !center.isBusy }
        #expect(runner.calls.count == 1)
    }

    @Test func cancellingARunningJobCancelsItsTask() async throws {
        let center = center(maxConcurrent: 1)
        runner.ignoresCancel = true
        let running = start(center)
        let next = start(center)
        try await eventually { runner.calls.count == 1 }
        center.cancel(running)
        // Off the card at once, and its place goes to the next in line.
        #expect(center.jobs.map(\.id) == [next])
        try await eventually { runner.calls.count == 2 }
        // The call learns of it; whatever it still answers is nobody's.
        runner.finish(0, Self.download)
        try await eventually { runner.cancelled == [0] }
        #expect(center.jobs.map(\.id) == [next])
        #expect(environment.ingested.isEmpty)
        #expect(environment.failures.isEmpty)
    }

    /// An extension that can no longer run (off, removed, waiting for consent) loses its
    /// running and waiting jobs; other extensions' jobs and finished cards stay.
    @Test func cancellingAnExtensionsJobsLeavesTheOthers() async throws {
        let center = center(maxConcurrent: 2)
        let finished = start(center)
        try await eventually { runner.calls.count == 1 }
        runner.finish(0, .text("hazır"))
        try await eventually { job(finished, in: center)?.phase == .ready }
        let running = start(center)
        let other = center.start(ExtensionCommand(id: "dev.example.other/a", extensionID: "dev.example.other", extensionName: "Other",
                                                  icon: "sf:number", title: "Other", subtitle: nil, keywords: [], input: .item, output: .text,
                                                  hint: false, priority: 0, actionID: "a", variant: nil, source: .local, accepts: nil,
                                                  targets: [], isJob: true, verb: nil),
                                 subjectID: 7, subjectTitle: "x", target: nil, toClipboard: false)
        let queued = start(center)
        try await eventually { runner.calls.count == 3 }
        #expect(job(queued, in: center)?.phase == .queued)

        center.cancelJobs { $0.extensionID == Self.video.extensionID }
        #expect(center.jobs.map(\.id) == [finished, other])
        #expect(job(other, in: center)?.phase == .running)
        #expect(job(finished, in: center)?.phase == .ready)
        try await eventually { runner.cancelled == [1] }
        // The waiting one never ran.
        #expect(runner.calls.count == 3)
        #expect(environment.failures.isEmpty)
        _ = running
    }

    @Test func cancelAllStopsEverything() async throws {
        let center = center()
        for _ in 0..<4 { start(center) }
        try await eventually { runner.calls.count == 3 }
        center.cancelAll()
        #expect(center.jobs.isEmpty)
        #expect(!center.isBusy)
        try await eventually { runner.cancelled == [0, 1, 2] }
        #expect(runner.calls.count == 3)
        #expect(environment.ingested.isEmpty)
        #expect(environment.failures.isEmpty)
    }

    // MARK: Delivery (never into the wrong app)

    @Test func aFinishedJobPastesWhenItsTargetIsInFront() async throws {
        environment.frontmost = "com.apple.finder"
        let center = center()
        let id = start(center)
        try await eventually { runner.calls.count == 1 }
        runner.finish(0, Self.download)
        try await eventually { job(id, in: center)?.phase == .done }
        let done = try #require(job(id, in: center))
        #expect(done.delivery == .pasted)
        #expect(done.resultName == "SwiftUI ile Liquid Glass.mp4")
        #expect(environment.ingested == [Self.download])
        #expect(environment.pasted == [101])
        #expect(environment.copied.isEmpty)
        #expect(environment.stacked.isEmpty)
        #expect(!center.isBusy)
        // The card says so for 3.6 s.
        clock.advance(by: .milliseconds(3500))
        #expect(center.jobs.count == 1)
        clock.advance(by: .milliseconds(100))
        #expect(center.jobs.isEmpty)

        // A paste that does not land leaves the result on the clipboard, ready.
        environment.pasteLands = false
        let missed = start(center)
        try await eventually { runner.calls.count == 2 }
        runner.finish(1, Self.download)
        try await eventually { job(missed, in: center)?.phase == .ready }
        #expect(job(missed, in: center)?.delivery == nil)
        #expect(environment.pasted == [101, 102])
        #expect(environment.copied == [102])
    }

    @Test func aFinishedJobWaitsWhenTheTargetLeft() async throws {
        environment.frontmost = "com.apple.Safari"
        let center = center()
        let id = start(center)
        try await eventually { runner.calls.count == 1 }
        runner.finish(0, Self.download)
        try await eventually { job(id, in: center)?.phase == .ready }
        #expect(job(id, in: center)?.delivery == nil)
        #expect(job(id, in: center)?.resultName == "SwiftUI ile Liquid Glass.mp4")
        #expect(environment.copied == [101])
        #expect(environment.ingested == [Self.download])

        // A job that never knew its target pastes nowhere, whoever is in front.
        environment.frontmost = nil
        let unknown = start(center, target: nil)
        try await eventually { runner.calls.count == 2 }
        runner.finish(1, Self.download)
        try await eventually { job(unknown, in: center)?.phase == .ready }
        #expect(environment.copied == [101, 102])
        #expect(environment.pasted.isEmpty)
    }

    @Test func aFinishedJobWaitsWhileThePanelIsOpen() async throws {
        environment.frontmost = "com.apple.finder"
        environment.isPanelVisible = true
        let center = center()
        let id = start(center)
        try await eventually { runner.calls.count == 1 }
        runner.finish(0, Self.download)
        try await eventually { job(id, in: center)?.phase == .ready }
        #expect(environment.copied == [101])
        #expect(environment.pasted.isEmpty)
    }

    @Test func copyJobsNeverPaste() async throws {
        environment.frontmost = "com.apple.finder"
        let center = center()
        let id = start(center, toClipboard: true)
        try await eventually { runner.calls.count == 1 }
        runner.finish(0, Self.download)
        try await eventually { job(id, in: center)?.phase == .ready }
        #expect(environment.copied == [101])
        #expect(environment.pasted.isEmpty)
    }

    @Test func onlyTheNewestReadyResultPromisesCommandV() async throws {
        environment.frontmost = "com.apple.Safari"
        let center = center()
        let first = start(center)
        let second = start(center)
        try await eventually { runner.calls.count == 2 }
        runner.finish(0, .text("ilk"))
        try await eventually { job(first, in: center)?.phase == .ready }
        clock.advance(by: .seconds(8))
        runner.finish(1, .text("ikinci"))
        try await eventually { job(second, in: center)?.phase == .ready }
        #expect(job(first, in: center)?.phase == .superseded)
        #expect(environment.copied == [101, 102])

        // The older card's time starts over at 2.6 s, though its 9 s as ready have passed.
        clock.advance(by: .milliseconds(1500))
        #expect(center.jobs.map(\.id) == [first, second])
        clock.advance(by: .milliseconds(1200))
        #expect(center.jobs.map(\.id) == [second])
        // The newer one keeps its 9 s.
        clock.advance(by: .milliseconds(6200))
        #expect(center.jobs.map(\.id) == [second])
        clock.advance(by: .milliseconds(200))
        #expect(center.jobs.isEmpty)
    }

    @Test func aPastedResultSupersedesAnOlderReadyOne() async throws {
        environment.frontmost = "com.apple.Safari"
        let center = center()
        let ready = start(center)
        let stacked = start(center)
        let pasted = start(center)
        try await eventually { runner.calls.count == 3 }
        runner.finish(0, .text("hazır"))
        try await eventually { job(ready, in: center)?.phase == .ready }

        // Joining the Sıra leaves the clipboard alone: the ready card still holds.
        environment.isStackOpen = true
        runner.finish(1, .text("sırada"))
        try await eventually { job(stacked, in: center)?.phase == .done }
        #expect(job(stacked, in: center)?.delivery == .stacked)
        #expect(job(ready, in: center)?.phase == .ready)

        // A paste leaves its own item on the clipboard: the older promise is gone.
        environment.isStackOpen = false
        environment.frontmost = "com.apple.finder"
        clock.advance(by: .seconds(8))
        runner.finish(2, Self.download)
        try await eventually { job(pasted, in: center)?.phase == .done }
        #expect(job(pasted, in: center)?.delivery == .pasted)
        #expect(job(ready, in: center)?.phase == .superseded)
        // Its time starts over at 2.6 s, though its 9 s as ready have passed.
        clock.advance(by: .milliseconds(1500))
        #expect(center.jobs.map(\.id) == [ready, pasted])
        clock.advance(by: .milliseconds(1200))
        #expect(center.jobs.map(\.id) == [pasted])
    }

    /// The person copies something else, so a result is no longer waiting on the
    /// clipboard; its ready card stops promising ⌘V and leaves after the superseded time. Done and
    /// failed cards are untouched.
    @Test func aNewCopyWithdrawsTheReadyPromise() async throws {
        let center = center()
        environment.frontmost = "com.apple.finder"
        let done = start(center)
        let failed = start(center)
        try await eventually { runner.calls.count == 2 }
        runner.finish(0, Self.download)
        try await eventually { job(done, in: center)?.phase == .done }
        runner.fail(1, ExtensionError(.script, "Bu video özel."))
        try await eventually { job(failed, in: center)?.phase == .failed }
        environment.frontmost = "com.apple.Safari"
        let ready = start(center)
        try await eventually { runner.calls.count == 3 }
        runner.finish(2, .text("hazır"))
        try await eventually { job(ready, in: center)?.phase == .ready }

        center.clipboardChanged()
        #expect(job(ready, in: center)?.phase == .superseded)
        #expect(job(done, in: center)?.phase == .done)
        #expect(job(failed, in: center)?.phase == .failed)
        clock.advance(by: .milliseconds(2500))
        #expect(job(ready, in: center) != nil)
        clock.advance(by: .milliseconds(200))
        #expect(job(ready, in: center) == nil)
        #expect(center.jobs.map(\.id) == [done, failed])
    }

    @Test func withTheStackOpenAnUnpastedResultJoinsTheStack() async throws {
        environment.frontmost = "com.apple.Safari"
        environment.isStackOpen = true
        let center = center()
        let id = start(center)
        try await eventually { runner.calls.count == 1 }
        runner.finish(0, Self.download)
        try await eventually { job(id, in: center)?.phase == .done }
        #expect(job(id, in: center)?.delivery == .stacked)
        #expect(environment.stacked == [101])
        #expect(environment.copied.isEmpty)
        #expect(environment.pasted.isEmpty)

        // A paste that does not land joins the Sıra too, and the clipboard stays as it was.
        environment.frontmost = "com.apple.finder"
        environment.pasteLands = false
        let missed = start(center)
        try await eventually { runner.calls.count == 2 }
        runner.finish(1, Self.download)
        try await eventually { job(missed, in: center)?.phase == .done }
        #expect(job(missed, in: center)?.delivery == .stacked)
        #expect(environment.pasted == [102])
        #expect(environment.stacked == [101, 102])
        #expect(environment.copied.isEmpty)
    }

    /// A paste that does not land has already put the result on the clipboard. With the
    /// Sıra open its head goes back there: when the result joins the Sıra, and when the card was closed
    /// while it pasted (then nothing joins).
    @Test func aPasteThatDoesNotLandGivesTheClipboardBackToTheStack() async throws {
        environment.frontmost = "com.apple.finder"
        environment.isStackOpen = true
        environment.stackHead = 50
        environment.pasteLands = false
        let center = center()
        let joined = start(center)
        try await eventually { runner.calls.count == 1 }
        runner.finish(0, Self.download)
        try await eventually { job(joined, in: center)?.phase == .done }
        #expect(environment.stacked == [101])
        #expect(environment.clipboard == 50)

        environment.holdsPaste = true
        let closed = start(center)
        try await eventually { runner.calls.count == 2 }
        runner.finish(1, Self.download)
        try await eventually { environment.isPasting }
        center.dismiss(closed)
        environment.releasePaste()
        try await Task.sleep(for: .milliseconds(50))
        #expect(job(closed, in: center) == nil)
        #expect(environment.pasted == [101, 102])
        #expect(environment.stacked == [101])
        #expect(environment.clipboard == 50)
    }

    // MARK: Failure and progress

    @Test func aFailureKeepsTheExtensionsMessage() async throws {
        let center = center()
        let id = start(center)
        try await eventually { runner.calls.count == 1 }
        runner.fail(0, ExtensionError(.script, "Video indirilemedi: yt-dlp güncellenmeli"))
        try await eventually { job(id, in: center)?.phase == .failed }
        #expect(job(id, in: center)?.errorMessage == "Video indirilemedi: yt-dlp güncellenmeli")
        #expect(environment.failures.map(\.id) == [id])
        #expect(environment.failures.first?.errorMessage == "Video indirilemedi: yt-dlp güncellenmeli")
        #expect(environment.ingested.isEmpty)
        #expect(!center.isBusy)
        // It stays until it is dismissed.
        clock.advance(by: .seconds(600))
        #expect(center.jobs.map(\.id) == [id])
        center.dismiss(id)
        #expect(center.jobs.isEmpty)

        // {none, message} fails with its message and stays out of history; {none} alone just leaves.
        let refused = start(center)
        try await eventually { runner.calls.count == 2 }
        runner.finish(1, .none(message: "Bu gönderi giriş istiyor"))
        try await eventually { job(refused, in: center)?.phase == .failed }
        #expect(job(refused, in: center)?.errorMessage == "Bu gönderi giriş istiyor")
        #expect(environment.failures.map(\.id) == [id, refused])
        start(center)
        try await eventually { runner.calls.count == 3 }
        runner.finish(2, .none(message: nil))
        try await eventually { !center.isBusy }
        #expect(center.jobs.map(\.id) == [refused])
        #expect(environment.ingested.isEmpty)
        #expect(environment.failures.count == 2)
    }

    /// The card words app-made failures in the app's language: it needs the code, not only the message.
    @Test func aFailureKeepsItsCode() async throws {
        let center = center()
        let missing = start(center)
        try await eventually { runner.calls.count == 1 }
        runner.fail(0, ExtensionError(.toolMissing, "yt-dlp is not installed"))
        try await eventually { job(missing, in: center)?.phase == .failed }
        #expect(job(missing, in: center)?.errorCode == .toolMissing)
        #expect(job(missing, in: center)?.errorMessage == "yt-dlp is not installed")
        #expect(environment.failures.first?.errorCode == .toolMissing)

        // {none, message} is the extension's own word, and a result history refused has no code either.
        let refused = start(center)
        try await eventually { runner.calls.count == 2 }
        runner.finish(1, .none(message: "Bu gönderi giriş istiyor"))
        try await eventually { job(refused, in: center)?.phase == .failed }
        #expect(job(refused, in: center)?.errorCode == nil)
        environment.ingestFails = true
        let unkept = start(center)
        try await eventually { runner.calls.count == 3 }
        runner.finish(2, Self.download)
        try await eventually { job(unkept, in: center)?.phase == .failed }
        #expect(job(unkept, in: center)?.errorCode == nil)
        #expect(job(unkept, in: center)?.errorMessage == nil)
    }

    @Test func progressIsAveragedOverKnownFractions() async throws {
        let center = center()
        let ids = (0..<3).map { _ in start(center) }
        try await eventually { runner.calls.count == 3 }
        #expect(center.aggregateFraction == nil)
        runner.calls[0].progress(0.2, "18,4 / 43,7 MB · 1 dk kaldı")
        runner.calls[1].progress(0.6, nil)
        runner.calls[2].progress(nil, "Birleştiriliyor")
        let average = try #require(center.aggregateFraction)
        #expect(abs(average - 0.4) < 1e-9)
        #expect(job(ids[0], in: center)?.fraction == 0.2)
        #expect(job(ids[0], in: center)?.message == "18,4 / 43,7 MB · 1 dk kaldı")
        #expect(job(ids[2], in: center)?.fraction == nil)
        #expect(job(ids[2], in: center)?.message == "Birleştiriliyor")

        // A finished job no longer counts.
        runner.finish(0, Self.download)
        try await eventually { job(ids[0], in: center)?.phase != .running }
        #expect(center.aggregateFraction == 0.6)
    }
}
