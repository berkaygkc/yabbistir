import Foundation
import Testing
import YabExtensionKit
import YabTestSupport
@testable import YabExtensionRuntime

/// `yab.exec` against fake tools: `#!/bin/sh` scripts in a temporary folder that serves as the search path.
@Suite struct ExecAPITests {
    let context = ExtensionContext(language: "en", trigger: .search)

    /// What the fixture's manifest asks for.
    static let required = [ToolSpec(name: "fake", install: "brew install fake"), ToolSpec(name: "yt-dlp", install: "brew install yt-dlp")]

    /// A fresh folder of fake tools, each a `#!/bin/sh` script with mode 0755.
    static func tools(_ scripts: [String: String] = [:]) throws -> URL {
        let folder = TestScratch.url("yab-tools")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, body) in scripts {
            let file = folder.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return folder
    }

    func runtime(_ js: String, tools: URL, granted: [String] = ["fake", "yt-dlp"], permissions: [String] = ["exec"],
                 log: @escaping @Sendable (String) -> Void = { _ in }) throws -> ExtensionRuntime {
        var manifest = RuntimeFixture.manifest
        manifest["permissions"] = ["exec"]
        manifest["requires"] = ["tools": Self.required.map { ["name": $0.name, "install": $0.install] }]
        let folder = try RuntimeFixture.folder(js: js, manifest: manifest)
        guard case .valid(let parsed, let localization) = ManifestValidator.validate(folder: folder) else {
            fatalError("fixture manifest is invalid: \(ManifestValidator.validate(folder: folder).issues)")
        }
        return try ExtensionRuntime(folder: folder, manifest: parsed, localization: localization,
                                    dataFolder: TestScratch.url("yab-data"),
                                    grant: PermissionGrant(permissions: permissions, domains: [], tools: granted),
                                    toolSearchPath: [tools.path], log: log)
    }

    /// The text a run returns, or "code: message" for an error.
    func outcome(_ js: String, tools: URL, granted: [String] = ["fake", "yt-dlp"], permissions: [String] = ["exec"],
                 effects: Bool = true) async throws -> String {
        let runtime = try runtime(js, tools: tools, granted: granted, permissions: permissions)
        do throws(ExtensionError) {
            let output = try await runtime.invoke(.run, name: "a", item: nil, context: context, effects: effects)
            guard case .result(.text(let text)) = output else { return "unexpected \(output)" }
            return text
        } catch {
            return "\(error.code.rawValue): \(error.message)"
        }
    }

    /// A run that returns JSON text, decoded.
    func object(_ js: String, tools: URL) async throws -> [String: Any] {
        let text = try await outcome(js, tools: tools)
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            Issue.record("not an object: \(text)")
            return [:]
        }
        return object
    }

    /// How long a fake tool may take to start: macOS assesses a newly written executable on its first
    /// run, after the spawn has returned and one at a time across the system (about 1.5 s here; up to
    /// about 4.5 s in the full suite, where dozens start at once). Nothing else a test waits on (a call,
    /// a loop) may end sooner, or it races the start.
    static let starting: Duration = .seconds(10)

    func waitFor(_ limit: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition(), ContinuousClock.now - start < limit { try await Task.sleep(for: .milliseconds(20)) }
    }

    static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    /// The pids a fake tool printed as "<pid> <pid>".
    static func pids(_ line: String) -> [pid_t] {
        line.split(separator: " ").compactMap { pid_t($0) }
    }

    // MARK: Running

    @Test func aToolRunsWithItsArgumentsInTheWorkFolder() async throws {
        let tools = try Self.tools(["fake": #"echo "$PWD"; printf '%s\n' "$@""#])
        let js = #"""
        exports.actions = { a: { async run() {
          const lines = [];
          const r = await yab.exec("fake", ["one", "two words", "çağrı"], { onLine: (line, stream) => lines.push(stream + " " + line) });
          return { text: JSON.stringify({ dir: yab.files.workDir, lines, exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr }) };
        } } };
        """#
        let result = try await object(js, tools: tools)
        // The folder is gone with the call; its parent tells its real path (sh's $PWD has /var as /private/var).
        let workDir = URL(fileURLWithPath: try #require(result["dir"] as? String))
        let parent = try #require(WorkFolders.realPath(workDir.deletingLastPathComponent().path))
        let dir = parent + "/" + workDir.lastPathComponent
        #expect(result["lines"] as? [String] == ["stdout \(dir)", "stdout one", "stdout two words", "stdout çağrı"])
        #expect(result["exitCode"] as? Int == 0)
        #expect(result["stdout"] as? String == "\(dir)\none\ntwo words\nçağrı\n")
        #expect(result["stderr"] as? String == "")
    }

    @Test func noShellIsInvolved() async throws {
        let tools = try Self.tools(["fake": #"printf '%s\n' "$@""#])
        let js = #"""
        exports.actions = { a: { async run() {
          const args = ["a; touch pwned", "$(touch pwned)", "`touch pwned`", "a && touch pwned", "> pwned", "*"];
          const r = await yab.exec("fake", args);
          return { text: JSON.stringify({ verbatim: r.stdout === args.join("\n") + "\n", stdout: r.stdout,
                                          pwned: yab.files.exists(yab.files.workDir + "/pwned") }) };
        } } };
        """#
        let result = try await object(js, tools: tools)
        #expect(result["verbatim"] as? Bool == true, "\(result["stdout"] ?? "")")
        #expect(result["pwned"] as? Bool == false)
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/pwned"))
        #expect(!FileManager.default.fileExists(atPath: tools.appendingPathComponent("pwned").path))
    }

    @Test func theToolGetsItsOwnSmallEnvironment() async throws {
        let tools = try Self.tools(["fake": #"""
        printf '%s\n' "PATH=$PATH" "HOME=$HOME" "TMPDIR=$TMPDIR" "USER=$USER" "LANG=$LANG"
        env | cut -d= -f1 | sort | tr '\n' ' '
        """#])
        let js = #"exports.actions = { a: { async run() { return { text: (await yab.exec("fake", [])).stdout }; } } };"#
        let lines = try await outcome(js, tools: tools).split(separator: "\n").map(String.init)
        let helper = ProcessInfo.processInfo.environment
        #expect(lines.first == "PATH=\(tools.path):/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(lines.dropFirst().prefix(4) == ["HOME=\(helper["HOME"] ?? "")", "TMPDIR=\(helper["TMPDIR"] ?? "")",
                                                 "USER=\(helper["USER"] ?? "")", "LANG=\(helper["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8")"])
        // Only those; the rest is what sh sets for itself.
        let names = Set((lines.last ?? "").split(separator: " ").map(String.init))
        #expect(names.isSubset(of: ["PATH", "HOME", "TMPDIR", "USER", "LANG", "PWD", "SHLVL", "_", "OLDPWD"]), "\(names)")
        #expect(names.isSuperset(of: ["PATH", "LANG"]))
    }

    @Test func exitCodesAreReturnedNotThrown() async throws {
        let tools = try Self.tools(["fake": #"""
        echo out
        echo err >&2
        if [ "$1" = kill ]; then kill -KILL $$; fi
        exit "$1"
        """#])
        let js = #"""
        exports.actions = { a: { async run() {
          const failed = await yab.exec("fake", ["3"]);
          const killed = await yab.exec("fake", ["kill"]);
          return { text: JSON.stringify([failed.exitCode, failed.stdout, failed.stderr, killed.exitCode]) };
        } } };
        """#
        let text = try await outcome(js, tools: tools)
        #expect(text == #"[3,"out\n","err\n",137]"#)
    }

    @Test func inputGoesToStandardInputAndWithoutItStandardInputIsEmpty() async throws {
        let tools = try Self.tools(["fake": "cat"])
        let js = #"""
        exports.actions = { a: { async run() {
          const given = await yab.exec("fake", [], { input: "satır bir\nsatır iki" });
          const none = await yab.exec("fake", []);
          return { text: JSON.stringify([given.stdout, none.stdout, none.exitCode]) };
        } } };
        """#
        #expect(try await outcome(js, tools: tools) == #"["satır bir\nsatır iki","",0]"#)
    }

    @Test func theResultKeepsTheLast64KBOfEachStreamAndEveryLineIsHeard() async throws {
        let tools = try Self.tools(["fake": "tee /dev/stderr"])
        let js = #"""
        exports.actions = { a: { async run() {
          const input = Array.from({ length: 20000 }, (_, i) => "line " + String(i).padStart(5, "0")).join("\n") + "\n";
          const heard = { stdout: [], stderr: [] };
          const r = await yab.exec("fake", [], { input, onLine: (line, stream) => heard[stream].push(line) });
          const ordered = heard.stdout.every((line, i) => line === "line " + String(i).padStart(5, "0"));
          return { text: JSON.stringify({ out: heard.stdout.length, err: heard.stderr.length, ordered,
                                          stdoutBytes: new TextEncoder().encode(r.stdout).length, stderrBytes: new TextEncoder().encode(r.stderr).length,
                                          ends: r.stdout.endsWith("line 19999\n") && r.stderr.endsWith("line 19999\n"), total: input.length }) };
        } } };
        """#
        let result = try await object(js, tools: tools)
        #expect(result["total"] as? Int == 220_000)
        #expect(result["out"] as? Int == 20000)
        #expect(result["err"] as? Int == 20000)
        #expect(result["ordered"] as? Bool == true)
        #expect(result["stdoutBytes"] as? Int == 65_536)
        #expect(result["stderrBytes"] as? Int == 65_536)
        #expect(result["ends"] as? Bool == true)
    }

    @Test func argumentsMustBeAListOfStrings() async throws {
        let tools = try Self.tools(["fake": #"touch "$(dirname "$0")/ran""#])
        let js = #"""
        exports.actions = { a: { async run() {
          const out = [];
          for (const args of [undefined, "a b", ["a", 1], ["a\u0000b"], [null]]) {
            try { await yab.exec("fake", args); out.push("ran"); } catch (e) { out.push(e.code + ": " + e.message); }
          }
          return { text: out.join("\n") };
        } } };
        """#
        let text = try await outcome(js, tools: tools)
        #expect(text == Array(repeating: "badResult: args must be an array of strings", count: 5).joined(separator: "\n"))
        #expect(!FileManager.default.fileExists(atPath: tools.appendingPathComponent("ran").path))
    }

    // MARK: Who may run what

    @Test func aToolNotInRequiresIsDenied() async throws {
        let tools = try Self.tools(["fake": #"touch "$(dirname "$0")/ran""#, "other": #"touch "$(dirname "$0")/ran""#])
        let js = #"""
        exports.actions = { a: { async run() {
          try { await yab.exec("other", []); return { text: "ran" }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#
        #expect(try await outcome(js, tools: tools) == "permissionDenied: other is not in the extension's required tools")
        // Declared but not agreed to is not enough either, nor a grant without the permission.
        let fake = js.replacingOccurrences(of: #""other""#, with: #""fake""#)
        #expect(try await outcome(fake, tools: tools, granted: ["yt-dlp"]) == "permissionDenied: fake is not in the extension's required tools")
        #expect(try await outcome(fake, tools: tools, permissions: []) == "permissionDenied: dev.example.fixture has no exec permission")
        #expect(!FileManager.default.fileExists(atPath: tools.appendingPathComponent("ran").path))
    }

    /// A missing tool says how to get it.
    @Test func aMissingToolSaysHowToInstall() async throws {
        let tools = try Self.tools()
        let js = #"""
        exports.actions = { a: { async run() {
          try { await yab.exec("yt-dlp", ["--version"]); return { text: "ran" }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#
        let text = try await outcome(js, tools: tools)
        #expect(text == "toolMissing: yt-dlp is not installed. Install it with: brew install yt-dlp")
        #expect(text.contains("brew install yt-dlp"))
    }

    /// Hints, detectors and previews never run programs.
    @Test func hintsCannotRunTools() async throws {
        let tools = try Self.tools(["fake": #"touch "$(dirname "$0")/ran""#])
        let js = #"""
        exports.actions = { a: { async run() {
          try { await yab.exec("fake", []); return { text: "ran" }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#
        #expect(try await outcome(js, tools: tools, effects: false) == "permissionDenied: exec is not available in hints, detectors and previews")
        #expect(!FileManager.default.fileExists(atPath: tools.appendingPathComponent("ran").path))
    }

    // MARK: Stopping

    /// A cancel stops the tool and what it started, even when both ignore SIGTERM.
    @Test func cancellingKillsTheTool() async throws {
        let tools = try Self.tools(["fake": """
        trap '' TERM
        sleep 30 &
        echo "$$ $!"
        wait
        """])
        let sink = LogSink()
        let js = #"""
        exports.actions = { a: { async run() {
          try { await yab.exec("fake", [], { onLine: (line) => console.log("pids " + line) }); console.log("resolved"); }
          catch (e) { console.log("rejected " + e.code); throw e; }
          return { text: "finished" };
        } } };
        """#
        let runtime = try runtime(js, tools: tools, log: sink.append)
        let context = context
        let call = Task { try await runtime.invoke(.run, name: "a", item: nil, context: context, effects: true, callID: 11) }
        try await waitFor(Self.starting) { sink.lines.contains { $0.hasPrefix("pids ") } }
        let pids = Self.pids(String(try #require(sink.lines.first { $0.hasPrefix("pids ") }).dropFirst(5)))
        try #require(pids.count == 2)
        let start = ContinuousClock.now
        runtime.cancel(callID: 11)
        await #expect { _ = try await call.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        // Both ignore SIGTERM, so only the SIGKILL two seconds later stops them.
        #expect(pids.allSatisfy { !Self.isGone($0) })
        while !pids.allSatisfy(Self.isGone), ContinuousClock.now - start < .seconds(3) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(pids.allSatisfy(Self.isGone))
        #expect(ContinuousClock.now - start < .seconds(3))
        try await waitFor { sink.lines.contains("rejected cancelled") }
        #expect(sink.lines.contains("rejected cancelled"))
        #expect(!sink.lines.contains("resolved"))
    }

    /// The kill does not wait for the extension's queue, which a script stuck in a loop holds.
    ///
    /// The script loops until the test lets it go, so the queue is still held when the kill is checked
    /// however long the tool takes to start (`starting`). A loop of fixed length can end first: the
    /// call's end then stops the tool before it ever ran, and there is nothing left to kill.
    @Test func aScriptStuckInALoopDoesNotHoldUpTheKill() async throws {
        let tools = try Self.tools(["fake": """
        sleep 30 &
        echo "$$ $!" > "$(dirname "$0")/pids.tmp" && mv "$(dirname "$0")/pids.tmp" "$(dirname "$0")/pids"
        wait
        """])
        // Never yields: loops until `release` is in the work folder (a minute at most, so a failing test still ends).
        let js = #"""
        exports.actions = { a: { run() {
          console.log("workDir " + yab.files.workDir);
          yab.exec("fake", []).catch((e) => console.log("rejected " + e.code + ": " + e.message));
          const release = yab.files.workDir + "/release", end = Date.now() + 60000;
          while (!yab.files.exists(release) && Date.now() < end) {}
          console.log("looped");
          return { text: "done" };
        } } };
        """#
        let logs = LogSink()
        let runtime = try runtime(js, tools: tools, log: logs.append)
        let context = context
        let call = Task { try await runtime.invoke(.run, name: "a", item: nil, context: context, effects: true, callID: 13) }
        func release() {
            guard let line = logs.lines.first(where: { $0.hasPrefix("workDir ") }) else { return }
            FileManager.default.createFile(atPath: String(line.dropFirst("workDir ".count)) + "/release", contents: nil)
        }
        defer { release() }
        let file = tools.appendingPathComponent("pids").path
        try await waitFor(Self.starting) { FileManager.default.fileExists(atPath: file) }
        let pids = Self.pids((try? String(contentsOfFile: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        try #require(pids.count == 2, "the tool wrote no pids; log: \(logs.lines)")
        runtime.cancel(callID: 13)
        try await waitFor(.seconds(1)) { pids.allSatisfy(Self.isGone) }
        #expect(pids.allSatisfy(Self.isGone))
        // Still looping: the kill came while the queue was held.
        #expect(!logs.lines.contains("looped"), "\(logs.lines)")
        release()
        // The run returns before the queued cancel lands, so it may end either way; only the kill matters here.
        _ = await call.result
        #expect(logs.lines.contains("looped"))
    }

    /// A tool a cancelled call starts before the cancel reaches its queue is stopped at once.
    @Test func aToolStartedAfterItsCallWasCancelledStopsAtOnce() async throws {
        final class Outcomes: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [ToolProcess.Outcome] = []
            var all: [ToolProcess.Outcome] { lock.withLock { storage } }
            func append(_ outcome: ToolProcess.Outcome) { lock.withLock { storage.append(outcome) } }
        }
        let owner = ToolRegistry.shared.newOwner()
        ToolRegistry.shared.cancel(owner: owner, callID: 1)
        let outcomes = Outcomes()
        let process = ToolProcess(onLine: nil, onExit: outcomes.append)
        #expect(ToolRegistry.shared.add(process, owner: owner, callID: 1))
        try process.start(executable: "/bin/sleep", arguments: ["30"], environment: [], directory: NSTemporaryDirectory(), input: nil)
        try await waitFor(.seconds(1)) { !outcomes.all.isEmpty }
        #expect(outcomes.all.map(\.exitCode) == [128 + SIGTERM])
        ToolRegistry.shared.end(owner: owner, callID: 1)
    }

    @Test func abortingTheSignalStopsTheTool() async throws {
        let tools = try Self.tools(["fake": """
        sleep 30 &
        echo "$$ $!"
        wait
        """])
        let js = #"""
        exports.actions = { a: { async run() {
          const controller = new AbortController();
          let pids = "";
          try {
            await yab.exec("fake", [], { signal: controller.signal, onLine: (line) => { pids = line; controller.abort(); } });
            return { text: "resolved" };
          } catch (e) {
            let early = "";
            try { await yab.exec("fake", [], { signal: controller.signal }); early = "ran"; } catch (f) { early = f.code; }
            return { text: e.code + "|" + early + "|" + pids };
          }
        } } };
        """#
        let parts = try await outcome(js, tools: tools).split(separator: "|").map(String.init)
        try #require(parts.count == 3)
        #expect(parts[0] == "cancelled")
        #expect(parts[1] == "cancelled")
        let pids = Self.pids(parts[2])
        try #require(pids.count == 2)
        try await waitFor(.seconds(1)) { pids.allSatisfy(Self.isGone) }
        #expect(pids.allSatisfy(Self.isGone))
    }

    /// A finished (not cancelled) exec that listened to the call's signal lets go of the
    /// call: nothing the listener held keeps its scope alive.
    @Test func aFinishedExecLetsGoOfItsCall() async throws {
        let tools = try Self.tools(["fake": "echo hi"])
        let js = #"exports.actions = { a: { async run(item, ctx) { await yab.exec("fake", [], { signal: ctx.signal }); return { text: "done" }; } } };"#
        let runtime = try runtime(js, tools: tools)
        weak var released: CallScope?
        do {
            let scope = CallScope(callID: 1, extensionID: runtime.extensionID, grant: runtime.grant, effects: true)
            released = scope
            #expect(try await runtime.call(.run, name: "a", arguments: [.null, .object([:])], in: scope) == .object(["text": .string("done")]))
        }
        try await waitFor(.seconds(1)) { released == nil }
        #expect(released == nil)
    }

    /// Nothing a finished call started keeps running: neither a tool it did not wait for nor what a tool left behind.
    @Test func aCallThatEndsStopsItsToolsAndWhatTheyLeft() async throws {
        let tools = try Self.tools(["fake": """
        if [ "$1" = leave ]; then sleep 30 >/dev/null 2>&1 & echo "$!"; exit 0; fi
        sleep 30 &
        echo "$$ $!"
        wait
        """])
        let js = #"""
        exports.actions = { a: { async run() {
          const running = await new Promise((resolve) => { yab.exec("fake", [], { onLine: resolve }).catch(() => {}); });
          const left = (await yab.exec("fake", ["leave"])).stdout.trim();
          return { text: running + " " + left };
        } } };
        """#
        let pids = Self.pids(try await outcome(js, tools: tools))
        try #require(pids.count == 3)
        try await waitFor { pids.allSatisfy(Self.isGone) }
        #expect(pids.allSatisfy(Self.isGone))
    }
}
