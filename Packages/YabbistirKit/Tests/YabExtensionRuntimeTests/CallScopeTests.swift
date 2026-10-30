import Foundation
import JavaScriptCore
import Testing
import YabExtensionKit
@testable import YabExtensionRuntime

@Suite struct CallScopeTests {
    let context = ExtensionContext(language: "en", trigger: .search)

    func text(_ output: InvokeOutput) -> String? {
        if case .result(.text(let text)) = output { text } else { nil }
    }

    /// A thrown Error reads as the extension wrote it; the line it came from goes to the development log.
    @Test func aThrownErrorKeepsItsMessageAndLogsItsLine() async throws {
        let js = "exports.actions = { a: { run() {\n  throw new Error(\"Nope, try again\");\n} } };"
        let sink = LogSink()
        let runtime = try RuntimeFixture.load(js: js, log: sink.append)
        do throws(ExtensionError) {
            _ = try await runtime.invoke(.run, name: "a", item: nil, context: context)
            Issue.record("expected a failure")
        } catch {
            #expect(error.code == .script)
            #expect(error.message == "Nope, try again")
        }
        #expect(sink.lines.contains { $0.contains("failed at line 2") })
        #expect(!sink.lines.contains { $0.contains("Nope") })
    }

    @Test func abortControllerBehavesLikeTheWeb() async throws {
        let js = #"""
        exports.actions = { a: { async run() {
          const c = new AbortController();
          let heard = 0, handled = 0, type = "";
          const listener = (e) => { heard++; type = e.type; };
          const removed = () => { heard += 100; };
          c.signal.addEventListener("abort", listener);
          c.signal.addEventListener("abort", listener);
          c.signal.addEventListener("abort", removed);
          c.signal.removeEventListener("abort", removed);
          c.signal.onabort = () => { handled++; };
          const before = c.signal.aborted;
          c.abort("why");
          c.abort("again");
          let thrown = "";
          try { c.signal.throwIfAborted(); } catch (e) { thrown = e; }
          const plain = new AbortController();
          plain.abort();
          const timed = AbortSignal.timeout(10);
          await new Promise(r => setTimeout(r, 60));
          let constructed = "allowed";
          try { new AbortSignal(); } catch (e) { constructed = e.name; }
          return { text: [before, c.signal.aborted, c.signal.reason, heard, handled, type, thrown,
                          plain.signal.reason.name, timed.aborted, timed.reason.name, constructed].join("|") };
        } } };
        """#
        let output = try await RuntimeFixture.load(js: js).invoke(.run, name: "a", item: nil, context: context)
        #expect(text(output) == "false|true|why|1|1|abort|why|AbortError|true|TimeoutError|TypeError")
    }

    /// A cancel ends the call at once, fires its signal and rejects the yab promise it waits on.
    @Test func cancellingRejectsPendingYabPromises() async throws {
        let sink = LogSink()
        let js = #"""
        exports.actions = { a: { async run(item, ctx) {
          ctx.signal.addEventListener("abort", () => console.log("signal " + ctx.signal.reason.code));
          const sleeping = slow();
          console.log("waiting");
          try { await sleeping; console.log("resolved"); } catch (e) { console.log("rejected " + e.code); }
          return { text: "finished anyway" };
        } } };
        """#
        let runtime = try RuntimeFixture.load(js: js, log: sink.append)
        runtime.queue.sync {
            let slow: @convention(block) () -> JSValue? = { [weak runtime] in
                runtime?.promise { Thread.sleep(forTimeInterval: 1); return .success(.null) }
            }
            runtime.context.setObject(unsafeBitCast(slow, to: AnyObject.self), forKeyedSubscript: "slow" as NSString)
        }
        let context = context
        let call = Task { try await runtime.invoke(.run, name: "a", item: nil, context: context, effects: true, callID: 7) }
        try await waitFor { sink.lines.contains("waiting") }
        let start = ContinuousClock.now
        runtime.cancel(callID: 7)
        await #expect { _ = try await call.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        #expect(ContinuousClock.now - start < .milliseconds(800))
        while !sink.lines.contains("rejected cancelled"), ContinuousClock.now - start < .seconds(3) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sink.lines.contains("signal cancelled"))
        #expect(sink.lines.contains("rejected cancelled"))
        #expect(!sink.lines.contains("resolved"))
    }

    static let network = PermissionGrant(permissions: ["network"], domains: [], tools: [])

    /// Natives only tests have: `slow(ms)`, a `yab` promise that resolves after `ms`; `probe()`, the
    /// call the code runs in; `check()`, what `require("network")` says there.
    func installProbes(in runtime: ExtensionRuntime) {
        runtime.queue.sync {
            let slow: @convention(block) (Double) -> JSValue? = { [weak runtime] milliseconds in
                runtime?.promise { Thread.sleep(forTimeInterval: milliseconds / 1000); return .success(.string("slept")) }
            }
            let probe: @convention(block) () -> JSValue? = { [weak runtime] in
                guard let runtime else { return nil }
                let scope = runtime.currentScope
                return runtime.jsValue(.object(["id": scope.map { .number(Double($0.callID)) } ?? .null,
                                                "effects": scope.map { .bool($0.effects) } ?? .null]))
            }
            let check: @convention(block) () -> String = { [weak runtime] in
                guard let scope = runtime?.currentScope else { return "outside any call" }
                do throws(ExtensionError) {
                    try HostAPI.require("network", in: scope)
                    return "allowed"
                } catch {
                    return "\(error.code.rawValue): \(error.message)"
                }
            }
            for (name, function) in [("slow", unsafeBitCast(slow, to: AnyObject.self)), ("probe", unsafeBitCast(probe, to: AnyObject.self)),
                                     ("check", unsafeBitCast(check, to: AnyObject.self))] {
                runtime.context.setObject(function, forKeyedSubscript: name as NSString)
            }
        }
    }

    func waitFor(_ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition(), ContinuousClock.now - start < .seconds(3) { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// What a finished run leaves behind (a timer, a pending promise) has no effects left.
    @Test func aFinishedCallLosesItsEffects() async throws {
        let sink = LogSink()
        let js = #"""
        exports.actions = { a: { run() {
          console.log("during " + check());
          slow(200).then(() => console.log("pending resolved"), (e) => console.log("pending " + e.code));
          setTimeout(() => {
            console.log("after " + check());
            slow(10).then(() => console.log("new resolved"), (e) => console.log("new " + e.code));
          }, 50);
          return { text: "done" };
        } } };
        """#
        let runtime = try RuntimeFixture.load(js: js, grant: Self.network, log: sink.append)
        installProbes(in: runtime)
        let output = try await runtime.invoke(.run, name: "a", item: nil, context: context, effects: true, callID: 3)
        #expect(text(output) == "done")
        try await waitFor { sink.lines.count >= 4 }
        #expect(sink.lines.contains("during allowed"))
        #expect(sink.lines.contains("after permissionDenied: the call is over"))
        #expect(sink.lines.contains("pending permissionDenied"))
        #expect(sink.lines.contains("new permissionDenied"))
    }

    /// A cancelled run's leftover timer can no longer reach the network or run a program.
    @Test func aCancelledCallLosesItsEffects() async throws {
        let sink = LogSink()
        let js = #"""
        exports.actions = { a: { async run() {
          setTimeout(() => console.log("after " + check()), 400);
          console.log("waiting");
          await new Promise(() => {});
        } } };
        """#
        let runtime = try RuntimeFixture.load(js: js, grant: Self.network, log: sink.append)
        installProbes(in: runtime)
        let context = context
        let call = Task { try await runtime.invoke(.run, name: "a", item: nil, context: context, effects: true, callID: 4) }
        try await waitFor { sink.lines.contains("waiting") }
        runtime.cancel(callID: 4)
        await #expect { _ = try await call.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        try await waitFor { sink.lines.count >= 2 }
        #expect(sink.lines == ["waiting", "after cancelled: the call was cancelled"])
    }

    /// Up to three jobs of one extension run at once: each keeps its own id, effects and progress
    /// across timers and `yab` promises.
    @Test func overlappingCallsKeepTheirOwnScope() async throws {
        let js = #"""
        exports.actions = { a: { async run(item, ctx) {
          const { tag, timer, wait } = ctx.preferences;
          const mark = (step) => { const p = probe(); yab.job.progress(null, `${tag} ${step} ${p.id} ${p.effects}`); };
          mark(1);
          await new Promise(r => setTimeout(r, timer));
          mark(2);
          await slow(wait);
          mark(3);
          return { text: `${tag} ${ctx.signal.aborted}` };
        } } };
        """#
        let runtime = try RuntimeFixture.load(js: js)
        installProbes(in: runtime)
        let (sinkA, sinkB) = (LogSink(), LogSink())
        func context(_ tag: String, timer: Double, wait: Double) -> ExtensionContext {
            ExtensionContext(language: "en", preferences: ["tag": .string(tag), "timer": .number(timer), "wait": .number(wait)], trigger: .search)
        }
        // A: timer 20 ms, then waits until ~100 ms; B: timer 50 ms, done at ~80 ms. Both awaits overlap.
        async let a = runtime.invoke(.run, name: "a", item: nil, context: context("A", timer: 20, wait: 80), effects: true, callID: 101) {
            sinkA.append($1 ?? "")
        }
        async let b = runtime.invoke(.run, name: "a", item: nil, context: context("B", timer: 50, wait: 30), effects: false, callID: 202) {
            sinkB.append($1 ?? "")
        }
        let (outputA, outputB) = try await (a, b)
        #expect(text(outputA) == "A false")
        #expect(text(outputB) == "B false")
        #expect(sinkA.lines == ["A 1 101 true", "A 2 101 true", "A 3 101 true"])
        #expect(sinkB.lines == ["B 1 202 false", "B 2 202 false", "B 3 202 false"])
    }

    /// Cancelling one job leaves another of the same extension running untouched.
    @Test func cancellingOneCallLeavesTheOtherAlone() async throws {
        let sink = LogSink()
        let js = #"""
        exports.actions = { a: { async run(item, ctx) {
          const { tag, wait } = ctx.preferences;
          const sleeping = slow(wait);
          console.log(`${tag} waiting`);
          try { await sleeping; } catch (e) { console.log(`${tag} rejected ${e.code}`); throw e; }
          console.log(`${tag} resolved ${ctx.signal.aborted}`);
          return { text: `${tag} ${ctx.signal.aborted}` };
        } } };
        """#
        let runtime = try RuntimeFixture.load(js: js, log: sink.append)
        installProbes(in: runtime)
        func context(_ tag: String, wait: Double) -> ExtensionContext {
            ExtensionContext(language: "en", preferences: ["tag": .string(tag), "wait": .number(wait)], trigger: .search)
        }
        let (contextA, contextB) = (context("A", wait: 2000), context("B", wait: 600))
        let a = Task { try await runtime.invoke(.run, name: "a", item: nil, context: contextA, effects: true, callID: 1) }
        let b = Task { try await runtime.invoke(.run, name: "a", item: nil, context: contextB, effects: true, callID: 2) }
        // Cancelled only once both are inside their `await slow(...)`.
        try await waitFor { sink.lines.contains("A waiting") && sink.lines.contains("B waiting") }
        runtime.cancel(callID: 1)
        await #expect { _ = try await a.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        #expect(text(try await b.value) == "B false")
        try await waitFor { sink.lines.contains("A rejected cancelled") }
        #expect(sink.lines.filter { !$0.hasSuffix("waiting") } == ["A rejected cancelled", "B resolved false"])
    }

    /// Network and programs only in a run the person started, and only with the permission.
    @Test func requireNeedsEffectsAndThePermission() throws {
        let network = PermissionGrant(permissions: ["network"], domains: [], tools: [])
        func scope(_ grant: PermissionGrant, effects: Bool) -> CallScope {
            CallScope(callID: 1, extensionID: "dev.example.fixture", grant: grant, effects: effects)
        }
        #expect(throws: ExtensionError(.permissionDenied, "network is not available in hints, detectors and previews")) {
            try HostAPI.require("network", in: scope(network, effects: false))
        }
        #expect(throws: ExtensionError(.permissionDenied, "dev.example.fixture has no network permission")) {
            try HostAPI.require("network", in: scope(.empty, effects: true))
        }
        try HostAPI.require("network", in: scope(network, effects: true))
    }
}
