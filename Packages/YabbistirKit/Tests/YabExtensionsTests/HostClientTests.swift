import Foundation
import Testing
import YabExtensionKit
@testable import YabExtensions

/// A throwaway extension folder around some index.js.
enum ExtensionFixture {
    static func folder(id: String = "dev.example.fixture", name: String = "Fixture", permissions: [String] = [], js: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-ext-\(UUID().uuidString)/\(id)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("locales"), withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "id": id, "version": "1.0.0", "apiVersion": 1, "defaultLocale": "en", "name": "name", "description": "name",
            "icon": "sf:number", "author": "berkaygkc", "license": "MIT", "permissions": permissions,
            "contributes": ["actions": [["id": "a", "title": "name", "keywords": "keywords", "input": "none", "output": "text"]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: ["name": name, "keywords": ["fixture"]]).write(to: folder.appendingPathComponent("locales/en.json"))
        try js.write(to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        return folder
    }

    static var dataFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("yab-data-\(UUID().uuidString)") }
}

/// A transport that answers invokes with a scripted reply, or stays silent.
final class FakeTransport: HostTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var onLine: (@Sendable (Data) -> Void)?
    private(set) var sent: [HostRequest] = []
    private(set) var restarts = 0
    /// nil: never answer.
    let reply: (@Sendable (HostRequest) -> HostMessage?)?

    init(reply: (@Sendable (HostRequest) -> HostMessage?)?) { self.reply = reply }

    var invokes: Int { lock.withLock { sent.filter { $0.invoke != nil }.count } }
    var requests: [HostRequest] { lock.withLock { sent } }

    func start(onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) throws { lock.withLock { self.onLine = onLine } }

    func send(_ line: Data) {
        guard let request = try? JSONDecoder().decode(HostRequest.self, from: line) else { return }
        let handler = lock.withLock { () -> (@Sendable (Data) -> Void)? in sent.append(request); return onLine }
        guard let message = reply?(request), let data = try? JSONEncoder().encode(message) else { return }
        DispatchQueue.global().async { handler?(data) }
    }

    func restart() throws { lock.withLock { restarts += 1 } }
    func stop() {}
}

@MainActor func eventually(_ condition: () -> Bool) async throws {
    let start = ContinuousClock.now
    while !condition(), ContinuousClock.now - start < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@MainActor @Suite struct HostClientTests {
    let context = ExtensionContext(language: "en", trigger: .search)

    @Test func aRunRoundTripsThroughTheLoop() async throws {
        let client = ExtensionHostClient(transport: PipeTransport()) { _, _ in }
        let folder = try ExtensionFixture.folder(js: #"exports.actions = { a: { run: () => ({ text: "ok" }) } };"#)
        try await client.load("dev.example.fixture", folder: folder, dataFolder: ExtensionFixture.dataFolder, language: "en")
        let output = try await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, timeout: .seconds(5))
        #expect(output == .result(.text("ok")))
    }

    /// Review round 2, C: what a run or a preview returns never reaches the Development log, whatever its shape
    /// (hints run actions on clipboard text by themselves).
    @Test func aBadResultNeverLogsWhatWasReturned() async throws {
        var lines: [String] = []
        let client = ExtensionHostClient(transport: PipeTransport()) { _, line in lines.append(line) }
        let folder = try ExtensionFixture.folder(js: #"""
        exports.actions = {
          a: { run: (item) => Number(item.text) },
          b: { run: (item) => item.text.length > 3 },
          c: { run: (item) => ({ [item.text]: 1 }) },
        };
        exports.detectors = { d: { preview: (item) => [{ type: Number(item.text) }] } };
        """#)
        try await client.load("dev.example.fixture", folder: folder, dataFolder: ExtensionFixture.dataFolder, language: "en")
        let item = ExtensionItem(id: 1, kind: "text", text: "123456", copiedAt: Date())
        for (kind, name) in [(InvokeKind.run, "a"), (.run, "b"), (.run, "c"), (.preview, "d")] {
            await #expect { _ = try await client.invoke("dev.example.fixture", kind, name: name, item: item, context: context, timeout: .seconds(5)) }
                throws: { ($0 as? ExtensionError)?.code == .badResult }
            // Each bad result counts against it: three would turn it off before the fourth.
            client.reset("dev.example.fixture")
        }
        #expect(lines.count == 4)
        #expect(!lines.contains { $0.contains("123456") || $0.contains("returned true") })
    }

    @Test func logsArrive() async throws {
        var lines: [String] = []
        let client = ExtensionHostClient(transport: PipeTransport()) { id, line in lines.append("\(id) \(line)") }
        let folder = try ExtensionFixture.folder(js: #"exports.actions = { a: { run() { console.log("merhaba"); return { text: "" }; } } };"#)
        try await client.load("dev.example.fixture", folder: folder, dataFolder: ExtensionFixture.dataFolder, language: "en")
        _ = try await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, timeout: .seconds(5))
        try await eventually { lines.contains("dev.example.fixture merhaba") }
    }

    /// A host that never answers costs one timeout, then a fresh host.
    @Test func aHungCallTimesOutAndTheHostRestarts() async throws {
        let transport = FakeTransport(reply: nil)
        let client = ExtensionHostClient(transport: transport) { _, _ in }
        let start = ContinuousClock.now
        await #expect {
            _ = try await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, timeout: .milliseconds(500))
        } throws: { ($0 as? ExtensionError)?.code == .timeout }
        // Well short of the 5 s a hung call would cost; parallel suites delay the main-actor timer.
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(transport.restarts == 1)
    }

    nonisolated static func failing(_ id: Int) -> HostMessage { HostMessage(id: id, error: ExtensionError(.script, "boom")) }

    @Test func threeFailuresDisableTheExtension() async throws {
        let transport = FakeTransport { request in HostClientTests.failing(request.id) }
        let client = ExtensionHostClient(transport: transport) { _, _ in }
        var disabled: [String] = []
        client.onExtensionDisabled = { disabled.append($0) }
        for _ in 0..<3 {
            _ = try? await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, timeout: .seconds(2))
        }
        #expect(disabled == ["dev.example.fixture"])
        await #expect {
            _ = try await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, timeout: .seconds(2))
        } throws: { ($0 as? ExtensionError)?.code == .unavailable }
        #expect(transport.invokes == 3)
    }

    /// Three calls of `fixture` that fail with `code`, as jobs (no time limit) or not; whether it was turned off.
    func turnedOff(after code: ExtensionError.Code, timeout: Duration?) async -> Bool {
        let transport = FakeTransport { request in HostMessage(id: request.id, error: ExtensionError(code, "boom")) }
        let client = ExtensionHostClient(transport: transport) { _, _ in }
        var disabled: [String] = []
        client.onExtensionDisabled = { disabled.append($0) }
        for _ in 0..<3 {
            _ = try? await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, effects: true, timeout: timeout)
        }
        #expect(disabled == (client.isDisabled("dev.example.fixture") ? ["dev.example.fixture"] : []))
        return client.isDisabled("dev.example.fixture")
    }

    /// A failure the extension reports about the world (a missing tool, the network,
    /// a refused permission) never turns it off, as a job or not (only crashes count here).
    @Test(arguments: [ExtensionError.Code.toolMissing, .networkError, .permissionDenied])
    func reportedFailuresAreNotCounted(_ code: ExtensionError.Code) async {
        #expect(await !turnedOff(after: code, timeout: nil))
        #expect(await !turnedOff(after: code, timeout: .seconds(2)))
    }

    /// A job that throws its own error with a message reported a failure, it did not crash.
    @Test func aJobsOwnErrorsAreNotCounted() async {
        #expect(await !turnedOff(after: .script, timeout: nil))
    }

    /// A job of a broken extension (what it returns is no result, what it names is not
    /// there) still turns it off; a non-job call that throws still counts.
    @Test func aBrokenJobIsStillTurnedOff() async {
        #expect(await turnedOff(after: .badResult, timeout: nil))
        #expect(await turnedOff(after: .notFound, timeout: nil))
        #expect(await turnedOff(after: .script, timeout: .seconds(2)))
    }

    /// The card words a bad result itself; the app's reason goes to the Development log.
    @Test func aBadResultsReasonGoesToTheLog() async {
        var lines: [String] = []
        let transport = FakeTransport { request in
            HostMessage(id: request.id, error: ExtensionError(.badResult, "a file result must be a file in yab.files.workDir"))
        }
        let client = ExtensionHostClient(transport: transport) { id, line in lines.append("\(id) \(line)") }
        _ = try? await client.invoke("dev.example.fixture", .run, name: "download", item: nil, context: context, effects: true, timeout: nil)
        #expect(lines == ["dev.example.fixture download returned no result: a file result must be a file in yab.files.workDir"])
    }

    @Test func aSuccessResetsTheCount() async throws {
        let counter = Counter()
        let transport = FakeTransport { request in
            counter.next() == 2 ? HostMessage(id: request.id, ok: .result(.text("ok"))) : HostClientTests.failing(request.id)
        }
        let client = ExtensionHostClient(transport: transport) { _, _ in }
        var disabled: [String] = []
        client.onExtensionDisabled = { disabled.append($0) }
        for _ in 0..<4 {
            _ = try? await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, timeout: .seconds(2))
        }
        #expect(disabled.isEmpty)
    }

    /// Review C3: a host that stops reading never blocks the app; the call's clock is already running.
    @Test func sendingNeverBlocks() async throws {
        let transport = ProcessTransport(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["4"])
        let client = ExtensionHostClient(transport: transport) { _, _ in }
        let item = ExtensionItem(id: 1, kind: "text", text: String(repeating: "a", count: 8_000_000), copiedAt: Date())
        // The main actor keeps ticking while the request sits in a pipe nobody reads.
        let ticks = TickRecorder()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks.tick()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        await #expect {
            _ = try await client.invoke("dev.example.fixture", .run, name: "a", item: item, context: context, timeout: .milliseconds(300))
        } throws: { ($0 as? ExtensionError)?.code == .timeout }
        try await Task.sleep(for: .milliseconds(100))
        ticker.cancel()
        #expect(ticks.longestGap < .seconds(1))
        transport.stop()
    }

    /// Review C3: the transport queues the write; a host that is not reading never holds up the caller.
    @Test func aTransportSendReturnsAtOnce() throws {
        let transport = ProcessTransport(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["3"])
        try transport.start { _ in }
        let start = ContinuousClock.now
        transport.send(Data(repeating: 0x61, count: 8_000_000))
        #expect(ContinuousClock.now - start < .milliseconds(500))
        transport.stop()
    }

    /// Review I1: a call cut short by another call's timeout is not its extension's fault.
    @Test func restartCasualtiesAreNotCounted() async throws {
        let client = ExtensionHostClient(transport: FakeTransport(reply: nil)) { _, _ in }
        for _ in 0..<3 {
            async let innocent: InvokeOutput? = try? client.invoke("dev.example.innocent", .run, name: "a", item: nil, context: context,
                                                                  timeout: .seconds(20))
            await #expect(throws: ExtensionError.self) {
                _ = try await client.invoke("dev.example.stuck", .run, name: "a", item: nil, context: context, timeout: .milliseconds(200))
            }
            _ = await innocent
        }
        #expect(client.isDisabled("dev.example.stuck"))
        #expect(!client.isDisabled("dev.example.innocent"))
    }

    /// Review I1: an extension whose load hangs or fails is the one that gets turned off.
    @Test func aLoadThatHangsIsCountedAgainstItsExtension() async throws {
        let client = ExtensionHostClient(transport: FakeTransport(reply: nil), loadTimeout: .milliseconds(200)) { _, _ in }
        for _ in 0..<3 {
            await #expect(throws: ExtensionError.self) {
                try await client.load("dev.example.stuck", folder: URL(fileURLWithPath: "/tmp/x"), dataFolder: URL(fileURLWithPath: "/tmp/y"),
                                      language: "en")
            }
        }
        #expect(client.isDisabled("dev.example.stuck"))
    }

    /// Review I3: a host that dies fails its calls at once, without blaming them.
    @Test func aHostThatExitsFailsItsCallsAtOnce() async throws {
        let transport = ProcessTransport(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 0.3; exit 3"])
        let client = ExtensionHostClient(transport: transport) { _, _ in }
        let start = ContinuousClock.now
        await #expect {
            _ = try await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, timeout: .seconds(8))
        } throws: { ($0 as? ExtensionError)?.code == .interrupted }
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(!client.isDisabled("dev.example.fixture"))
        transport.stop()
    }

    /// Review C3: a slow load (a top-level loop) never stops the host from answering others.
    @Test func aSlowLoadDoesNotHoldUpOtherExtensions() async throws {
        let client = ExtensionHostClient(transport: PipeTransport()) { _, _ in }
        let quick = try ExtensionFixture.folder(id: "dev.example.quick", js: #"exports.actions = { a: { run: () => ({ text: "ok" }) } };"#)
        try await client.load("dev.example.quick", folder: quick, dataFolder: ExtensionFixture.dataFolder, language: "en")
        let slow = try ExtensionFixture.folder(id: "dev.example.slow",
                                               js: "const t = Date.now(); while (Date.now() - t < 3000) {}\nexports.actions = {};")
        async let slowLoad: Void? = try? client.load("dev.example.slow", folder: slow, dataFolder: ExtensionFixture.dataFolder, language: "en")
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        let output = try await client.invoke("dev.example.quick", .run, name: "a", item: nil, context: context, timeout: .seconds(8))
        #expect(output == .result(.text("ok")))
        #expect(ContinuousClock.now - start < .seconds(2))
        _ = await slowLoad
    }

    @Test func progressReachesTheCaller() async throws {
        let client = ExtensionHostClient(transport: PipeTransport()) { _, _ in }
        let folder = try ExtensionFixture.folder(js: #"""
        exports.actions = { a: { async run() {
          yab.job.progress(0.5, "yarı");
          await new Promise(r => setTimeout(r, 20));
          yab.job.progress(null, "Birleştiriliyor");
          return { text: "ok" };
        } } };
        """#)
        try await client.load("dev.example.fixture", folder: folder, dataFolder: ExtensionFixture.dataFolder, language: "en")
        var steps: [ProgressStep] = []
        let output = try await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, effects: true,
                                             timeout: .seconds(5)) { steps.append(ProgressStep(fraction: $0, message: $1)) }
        #expect(output == .result(.text("ok")))
        #expect(steps == [ProgressStep(fraction: 0.5, message: "yarı"), ProgressStep(fraction: nil, message: "Birleştiriliyor")])
    }

    /// Cancelling the caller's Task ends the call at once, without blame, and the
    /// host fires the call's signal.
    @Test func cancellingTheTaskAbortsTheSignal() async throws {
        var lines: [String] = []
        let client = ExtensionHostClient(transport: PipeTransport()) { id, line in lines.append("\(id) \(line)") }
        let folder = try ExtensionFixture.folder(js: #"""
        exports.actions = { a: { run: (item, ctx) => new Promise((_, rej) => {
          ctx.signal.addEventListener("abort", () => {
            console.log("aborted " + ctx.signal.reason.code);
            rej(new Error("x"));
          });
          console.log("waiting");
        }) } };
        """#)
        try await client.load("dev.example.fixture", folder: folder, dataFolder: ExtensionFixture.dataFolder, language: "en")
        let context = context
        let call = Task { try await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, effects: true, timeout: nil) }
        try await eventually { lines.contains("dev.example.fixture waiting") }
        let start = ContinuousClock.now
        call.cancel()
        await #expect { _ = try await call.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(!client.isDisabled("dev.example.fixture"))
        try await eventually { lines.contains("dev.example.fixture aborted cancelled") }
    }

    @Test func aCallWithoutATimeoutRunsLong() async throws {
        let client = ExtensionHostClient(transport: PipeTransport()) { _, _ in }
        let folder = try ExtensionFixture.folder(js: #"exports.actions = { a: { async run() { await new Promise(r => setTimeout(r, 1500)); return { text: "done" }; } } };"#)
        try await client.load("dev.example.fixture", folder: folder, dataFolder: ExtensionFixture.dataFolder, language: "en")
        let output = try await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, effects: true, timeout: nil)
        #expect(output == .result(.text("done")))
    }

    /// A cancel is the person's choice: never counted, never a restart, and the host hears of each one.
    @Test func cancelledCallsAreNotCounted() async throws {
        let transport = FakeTransport(reply: nil)
        let client = ExtensionHostClient(transport: transport) { _, _ in }
        let context = context
        for _ in 0..<3 {
            let call = Task { try await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, timeout: nil) }
            try await Task.sleep(for: .milliseconds(50))
            call.cancel()
            await #expect { _ = try await call.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        }
        #expect(!client.isDisabled("dev.example.fixture"))
        #expect(transport.restarts == 0)
        try await eventually { transport.requests.compactMap(\.cancel).count == 3 }
        #expect(transport.requests.compactMap(\.cancel).map(\.callID) == transport.requests.filter { $0.invoke != nil }.map(\.id))
    }

    /// A load request written before grants existed still reads, with nothing granted.
    @Test func aLoadRequestWithoutAGrantStillDecodes() throws {
        let old = #"{"extensionID":"dev.example.fixture","folder":"/f","dataFolder":"/d","language":"en"}"#
        let request = try JSONDecoder().decode(LoadRequest.self, from: Data(old.utf8))
        #expect(request.grant.isEmpty)
        #expect(request.toolSearchPath.isEmpty)
    }

    @Test func aKilledProcessIsGone() async throws {
        let transport = ProcessTransport(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let client = ExtensionHostClient(transport: transport) { _, _ in }
        _ = try? await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, timeout: .milliseconds(300))
        let firstPID = try #require(transport.processIdentifier)
        _ = try? await client.invoke("dev.example.fixture", .run, name: "a", item: nil, context: context, timeout: .milliseconds(300))
        #expect(transport.processIdentifier != firstPID)
        #expect(kill(firstPID, 0) != 0)
        transport.stop()
    }
}

@MainActor final class TickRecorder {
    private var last: ContinuousClock.Instant?
    private(set) var longestGap: Duration = .zero

    func tick() {
        let now = ContinuousClock.now
        if let last { longestGap = max(longestGap, now - last) }
        last = now
    }
}

struct ProgressStep: Equatable {
    let fraction: Double?
    let message: String?
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func next() -> Int { lock.withLock { value += 1; return value } }
}
