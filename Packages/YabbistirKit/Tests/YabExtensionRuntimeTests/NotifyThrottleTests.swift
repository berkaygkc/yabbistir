import Foundation
import Testing
import YabExtensionKit
import YabTestSupport
@testable import YabExtensionRuntime

/// A clock the test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { seconds } }
    func advance(by delta: TimeInterval) { lock.withLock { seconds += delta } }
}

@Suite struct NotifyThrottleTests {
    final class Harness: @unchecked Sendable {
        let clock = ManualClock()
        let sent = LogSink()
        let logs = LogSink()
        let runtime: ExtensionRuntime

        init(js: String) throws {
            let folder = try RuntimeFixture.folder(js: js)
            guard case .valid(let manifest, let localization) = ManifestValidator.validate(folder: folder) else {
                fatalError("fixture manifest is invalid")
            }
            let sent = sent, logs = logs, clock = clock
            let channel = HostCallChannel { message in
                if message.event == "call" { sent.append("\(message.method ?? "")|\(message.params?["message"]?.stringValue ?? "")") }
            }
            runtime = try ExtensionRuntime(folder: folder, manifest: manifest, localization: localization,
                                           dataFolder: TestScratch.url("yab-data"),
                                           hostCalls: channel, clock: { clock.now }) { logs.append($0) }
        }

        func run() async throws {
            _ = try await runtime.invoke(.run, name: "a", item: nil, context: ExtensionContext(language: "en", trigger: .search), effects: true)
        }
    }

    static let flood = #"exports.actions = { a: { run() { for (let i = 0; i < 20; i++) yab.notify("secret " + i); return { text: "ok" }; } } };"#

    @Test func aNotifyFloodIsCappedInTheHelper() async throws {
        let harness = try Harness(js: Self.flood)
        try await harness.run()
        #expect(harness.sent.lines.count == 5)
        #expect(harness.sent.lines.first == "notify|secret 0")
        // One line for the whole flood, and never the text.
        let lines = harness.logs.lines.filter { $0.contains("yab.notify") }
        #expect(lines.count == 1)
        #expect(lines.allSatisfy { !$0.contains("secret") && $0.contains("5") && $0.contains("10") })
    }

    @Test func theCapResetsAfterTheWindow() async throws {
        let harness = try Harness(js: Self.flood)
        try await harness.run()
        #expect(harness.sent.lines.count == 5)
        harness.clock.advance(by: 9)
        try await harness.run()
        #expect(harness.sent.lines.count == 5)
        harness.clock.advance(by: 1.5)
        try await harness.run()
        #expect(harness.sent.lines.count == 10)
        // The flood after the reset is worth its own line.
        #expect(harness.logs.lines.filter { $0.contains("yab.notify") }.count == 2)
    }
}
