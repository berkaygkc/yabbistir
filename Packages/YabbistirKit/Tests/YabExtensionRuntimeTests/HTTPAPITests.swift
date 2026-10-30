import Foundation
import Testing
import YabExtensionKit
@testable import YabExtensionRuntime

/// What the stub network did, shared by the tests of this suite (which therefore run one at a time).
final class StubNetwork: @unchecked Sendable {
    enum Reply {
        case response(status: Int, headers: [String: String], chunks: [Data])
        case redirect(to: String)
        /// Sends the head and some bytes, then never finishes.
        case hang(first: Data)
    }

    static let shared = StubNetwork()
    private let lock = NSLock()
    private var handler: @Sendable (URL) -> Reply = { _ in .response(status: 404, headers: [:], chunks: []) }
    private var seen: [URL] = []
    private var stopped = 0

    func reset(_ handler: @escaping @Sendable (URL) -> Reply) {
        lock.withLock { (self.handler, seen, stopped) = (handler, [], 0) }
    }

    var requests: [URL] { lock.withLock { seen } }
    var stops: Int { lock.withLock { stopped } }

    func reply(to url: URL) -> Reply {
        lock.withLock { seen.append(url); return handler }(url)
    }

    func didStop() { lock.withLock { stopped += 1 } }

    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }
}

final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        switch StubNetwork.shared.reply(to: url) {
        case .response(let status, let headers, let chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
        case .hang(let first):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: first)
        }
    }

    override func stopLoading() { StubNetwork.shared.didStop() }
}

@Suite(.serialized) struct HTTPAPITests {
    let context = ExtensionContext(language: "en", trigger: .search)
    let stub = StubNetwork.shared

    func grant(_ domains: [String] = [], permissions: [String] = ["network"]) -> PermissionGrant {
        PermissionGrant(permissions: permissions, domains: domains, tools: [])
    }

    func runtime(_ js: String, domains: [String] = [], permissions: [String] = ["network"]) throws -> ExtensionRuntime {
        let folder = try RuntimeFixture.folder(js: js)
        guard case .valid(let manifest, let localization) = ManifestValidator.validate(folder: folder) else { fatalError("fixture manifest") }
        return try ExtensionRuntime(folder: folder, manifest: manifest, localization: localization,
                                    dataFolder: FileManager.default.temporaryDirectory.appendingPathComponent("yab-data-\(UUID().uuidString)"),
                                    grant: grant(domains, permissions: permissions), urlSessionConfiguration: stub.configuration) { _ in }
    }

    /// The text a run returns, or "code: message" for an error.
    func outcome(_ js: String, domains: [String] = [], permissions: [String] = ["network"], effects: Bool = true) async throws -> String {
        let runtime = try runtime(js, domains: domains, permissions: permissions)
        do throws(ExtensionError) {
            let output = try await runtime.invoke(.run, name: "a", item: nil, context: context, effects: effects)
            guard case .result(.text(let text)) = output else { return "unexpected \(output)" }
            return text
        } catch {
            return "\(error.code.rawValue): \(error.message)"
        }
    }

    static func ok(_ body: String = "ok", headers: [String: String] = [:]) -> StubNetwork.Reply {
        .response(status: 200, headers: headers, chunks: [Data(body.utf8)])
    }

    @Test func fetchReturnsTextAndStatus() async throws {
        stub.reset { _ in Self.ok("ok", headers: ["Content-Type": "text/plain", "X-Thing": "1"]) }
        let js = #"""
        exports.actions = { a: { async run() {
          const r = await yab.http.fetch("https://example.com/a");
          const w = await fetch("https://example.com/a");
          const body = await w.text();
          return { text: [r.status, r.text, r.headers["content-type"], r.headers["x-thing"], w.ok, w.status, body, w.headers.get("Content-Type")].join("|") };
        } } };
        """#
        #expect(try await outcome(js) == "200|ok|text/plain|1|true|200|ok|text/plain")
    }

    @Test func fetchHandlesBinaryBodiesJSONAndOptions() async throws {
        stub.reset { _ in .response(status: 200, headers: [:], chunks: [Data([0, 255, 1, 128])]) }
        let js = #"""
        exports.actions = { a: { async run() {
          const bytes = Array.from(new Uint8Array(await (await fetch("https://example.com/b")).arrayBuffer()));
          return { text: bytes.join(",") };
        } } };
        """#
        #expect(try await outcome(js) == "0,255,1,128")
        stub.reset { _ in Self.ok(#"{"a":[1,2]}"#) }
        let json = #"""
        exports.actions = { a: { async run() {
          const r = await fetch("https://example.com/j", { method: "post", headers: new Headers({ "X-A": "1" }), body: "x" });
          return { text: JSON.stringify(await r.json()) };
        } } };
        """#
        #expect(try await outcome(json) == #"{"a":[1,2]}"#)
    }

    @Test func aHostOutsideTheDomainsIsDenied() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"""
        exports.actions = { a: { async run() {
          const out = [];
          for (const f of [(u) => yab.http.fetch(u), (u) => fetch(u)]) {
            try { await f("https://example.com/secret?token=abc"); out.push("fetched"); } catch (e) { out.push(e.code + ": " + e.message); }
          }
          return { text: out.join("\n") };
        } } };
        """#
        let text = try await outcome(js, domains: ["video.example"])
        #expect(text == Array(repeating: "permissionDenied: example.com is not in the extension's domains", count: 2).joined(separator: "\n"))
        #expect(!text.contains("secret"))
        #expect(stub.requests.isEmpty)
    }

    @Test func lookAlikeHostsAreDenied() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"""
        exports.actions = { a: { async run() {
          const out = [];
          for (const u of ["https://evilvideo.example/", "https://video.example.evil.com/", "https://video.example@evil.com/", "https://evil.com/video.example",
                           "https://www.video.example/", "https://Video.example./", "ftp://video.example/", "file:///etc/hosts", "data:text/plain,hi", "video.example"]) {
            try { await yab.http.fetch(u); out.push("ok"); } catch (e) { out.push(e.code); }
          }
          return { text: out.join(",") };
        } } };
        """#
        let text = try await outcome(js, domains: ["video.example"])
        #expect(text == "permissionDenied,permissionDenied,permissionDenied,permissionDenied,ok,ok,permissionDenied,permissionDenied,permissionDenied,permissionDenied")
        #expect(stub.requests.count == 2)
        #expect(Set(stub.requests.map { $0.host?.lowercased() ?? "" }) == ["www.video.example", "video.example."])
    }

    @Test func anEmptyDomainListAllowsEveryHostButOnlyWithTheNetworkPermission() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"exports.actions = { a: { async run() { return { text: (await yab.http.fetch("https://anything.example.org/")).text }; } } };"#
        #expect(try await outcome(js) == "ok")
        let denied = try await outcome(js, permissions: [])
        #expect(denied.hasPrefix("permissionDenied: ") && denied.hasSuffix("dev.example.fixture has no network permission"))
    }

    @Test func aRedirectOutsideTheDomainsFails() async throws {
        stub.reset { url in url.host == "video.example" ? .redirect(to: "https://example.com/landing?secret=1") : Self.ok("landed") }
        let js = #"""
        exports.actions = { a: { async run() {
          try { await yab.http.fetch("https://video.example/start"); return { text: "fetched" }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#
        #expect(try await outcome(js, domains: ["video.example"]) == "networkError: redirected outside the allowed domains (example.com)")
        #expect(stub.requests.map { $0.host ?? "" } == ["video.example"])
    }

    @Test func aRedirectInsideTheDomainsIsFollowed() async throws {
        stub.reset { url in url.host == "video.example" ? .redirect(to: "https://www.video.example/landing") : Self.ok("landed") }
        let js = #"exports.actions = { a: { async run() { return { text: (await yab.http.fetch("https://video.example/start")).text }; } } };"#
        #expect(try await outcome(js, domains: ["video.example"]) == "landed")
        #expect(stub.requests.map { $0.host ?? "" } == ["video.example", "www.video.example"])
    }

    @Test func aPercentEncodedHostIsDenied() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"""
        exports.actions = { a: { async run() {
          const out = [];
          for (const u of ["https://evil.com%2f.video.example/", "https://evil.com%40.video.example/", "https://evil.com%23.video.example/", "https://evil.com%3f.video.example/"]) {
            try { await yab.http.fetch(u); out.push("ok"); } catch (e) { out.push(e.code + ": " + e.message); }
          }
          return { text: out.join("\n") };
        } } };
        """#
        let text = try await outcome(js, domains: ["video.example"])
        #expect(text.split(separator: "\n").allSatisfy { $0.hasPrefix("permissionDenied: ") })
        #expect(text.split(separator: "\n").count == 4)
        #expect(!text.contains("evil"))
        #expect(stub.requests.isEmpty)
    }

    @Test func anIPLiteralMatchesOnlyExactly() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"""
        exports.actions = { a: { async run() {
          const out = [];
          for (const u of ["https://1.2.3.4/", "https://8.8.8.8/"]) {
            try { await yab.http.fetch(u); out.push("ok"); } catch (e) { out.push(e.code); }
          }
          return { text: out.join(",") };
        } } };
        """#
        #expect(try await outcome(js, domains: ["video.example"]) == "permissionDenied,permissionDenied")
        #expect(try await outcome(js, domains: ["8.8.8.8"]) == "permissionDenied,ok")
        #expect(DomainPolicy(domains: ["3.4"]).permits(host: "1.2.3.4") == false)
    }

    @Test func aPortDoesNotChangeTheHost() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"exports.actions = { a: { async run() { return { text: (await yab.http.fetch("https://www.video.example:8443/x")).text }; } } };"#
        #expect(try await outcome(js, domains: ["video.example"]) == "ok")
    }

    @Test func anIDNHostIsMatchedAsPunycode() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"exports.actions = { a: { async run() { return { text: (await yab.http.fetch("https://b\u00fccher.video.example/x")).text }; } } };"#
        #expect(try await outcome(js, domains: ["video.example"]) == "ok")
    }

    @Test func aRedirectToAnInvalidHostFails() async throws {
        stub.reset { url in url.host == "video.example" ? .redirect(to: "https://evil.com%2f.video.example/") : Self.ok("landed") }
        let js = #"""
        exports.actions = { a: { async run() {
          try { await yab.http.fetch("https://video.example/start"); return { text: "fetched" }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#
        #expect(try await outcome(js, domains: ["video.example"]) == "networkError: redirected outside the allowed domains (an invalid host)")
        #expect(stub.requests.count == 1)
    }

    @Test func largeBodiesStreamToAFile() async throws {
        let payload = Data((0..<(3 * 1_048_576 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let chunks = stride(from: 0, to: payload.count, by: 65_536).map { payload.subdata(in: $0..<min($0 + 65_536, payload.count)) }
        stub.reset { _ in .response(status: 200, headers: [:], chunks: chunks) }
        let js = #"exports.actions = { a: { async run() { const r = await yab.http.fetch("https://example.com/x", { toFile: "v.bin" }); return { file: r.file }; } } };"#
        let output = try await runtime(js).invoke(.run, name: "a", item: nil, context: context, effects: true)
        guard case .result(.file(let path)) = output else { Issue.record("expected a file result"); return }
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        #expect(URL(fileURLWithPath: path).lastPathComponent == "v.bin")
        #expect(FileManager.default.contents(atPath: path) == payload)
    }

    @Test func toFileTrueNamesTheFileAfterTheURL() async throws {
        stub.reset { _ in Self.ok("data") }
        let js = #"""
        exports.actions = { a: { async run() {
          const a = await yab.http.fetch("https://example.com/dir/clip%20one.mp4?x=1", { toFile: true });
          const b = await yab.http.fetch("https://example.com/", { toFile: true });
          const c = await yab.http.fetch("https://example.com/..", { toFile: true });
          return { text: [a.file, b.file, c.file].map((p) => p.split("/").pop()).join("|") };
        } } };
        """#
        #expect(try await outcome(js) == "clip one.mp4|download|download")
    }

    @Test func aBadToFileNameIsRefused() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"""
        exports.actions = { a: { async run() {
          try { await yab.http.fetch("https://example.com/", { toFile: "../x" }); return { text: "fetched" }; } catch (e) { return { text: e.code }; }
        } } };
        """#
        #expect(try await outcome(js) == "badResult")
        #expect(stub.requests.isEmpty)
    }

    @Test func aTextBodyOverTenMegabytesFails() async throws {
        let chunk = Data(repeating: 0x61, count: 1_048_576)
        stub.reset { _ in .response(status: 200, headers: [:], chunks: Array(repeating: chunk, count: 11)) }
        let js = #"""
        exports.actions = { a: { async run() {
          try { await yab.http.fetch("https://example.com/big"); return { text: "fetched" }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#
        #expect(try await outcome(js) == "networkError: the response is larger than 10 MB; pass toFile")
    }

    @Test func aFailedDownloadIsNotSavedAsTheFile() async throws {
        stub.reset { _ in .response(status: 404, headers: [:], chunks: [Data("nope".utf8)]) }
        let js = #"""
        exports.actions = { a: { async run() {
          const r = await yab.http.fetch("https://example.com/missing", { toFile: "v.bin" });
          return { text: [r.status, r.text, r.file, yab.files.exists(yab.files.workDir + "/v.bin")].join("|") };
        } } };
        """#
        #expect(try await outcome(js) == "404|nope||false")
    }

    @Test func withoutNetworkPermissionFetchIsDenied() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"""
        exports.actions = { a: { async run() {
          const out = [];
          for (const f of [(u) => yab.http.fetch(u), (u) => fetch(u)]) {
            try { await f("https://example.com/"); out.push("fetched"); } catch (e) { out.push(e.code + ": " + e.message); }
          }
          return { text: out.join("\n") };
        } } };
        """#
        let text = try await outcome(js, permissions: [])
        #expect(text == Array(repeating: "permissionDenied: dev.example.fixture has no network permission", count: 2).joined(separator: "\n"))
        #expect(stub.requests.isEmpty)
    }

    @Test func hintsCannotReachTheNetwork() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"""
        exports.actions = { a: { async run() {
          try { await yab.http.fetch("https://example.com/"); return { text: "fetched" }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#
        #expect(try await outcome(js, effects: false) == "permissionDenied: network is not available in hints, detectors and previews")
        #expect(stub.requests.isEmpty)
    }

    @Test func aTimerCannotFetchAfterTheCallEnded() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"""
        exports.actions = { a: { run() {
          setTimeout(() => { yab.http.fetch("https://example.com/late").catch(() => {}); }, 50);
          return { text: "done" };
        } } };
        """#
        #expect(try await outcome(js) == "done")
        try await Task.sleep(for: .milliseconds(300))
        #expect(stub.requests.isEmpty)
    }

    @Test func abortingTheSignalCancelsTheRequestAndRemovesThePartialFile() async throws {
        stub.reset { _ in .hang(first: Data(repeating: 1, count: 1000)) }
        let js = #"""
        exports.actions = { a: { async run() {
          const controller = new AbortController();
          setTimeout(() => controller.abort(), 150);
          const dir = yab.files.workDir;
          const out = [];
          for (const via of [(s) => yab.http.fetch("https://example.com/v", { toFile: "v.bin", signal: s }), (s) => fetch("https://example.com/v", { signal: s })]) {
            try { await via(controller.signal); out.push("fetched"); } catch (e) { out.push(e.code); }
          }
          return { text: out.join(",") + "|" + yab.files.exists(dir + "/v.bin") };
        } } };
        """#
        #expect(try await outcome(js) == "cancelled,cancelled|false")
        #expect(stub.stops >= 1)
    }

    @Test func cancellingTheCallCancelsTheRequestAndLeavesNoFile() async throws {
        stub.reset { _ in .hang(first: Data(repeating: 1, count: 1000)) }
        let sink = LogSink()
        let js = #"""
        exports.actions = { a: { async run() {
          console.log("dir " + yab.files.workDir);
          try { await yab.http.fetch("https://example.com/v", { toFile: "v.bin" }); } catch (e) { console.log("rejected " + e.code); }
          return { text: "x" };
        } } };
        """#
        let folder = try RuntimeFixture.folder(js: js)
        guard case .valid(let manifest, let localization) = ManifestValidator.validate(folder: folder) else { fatalError("fixture manifest") }
        let runtime = try ExtensionRuntime(folder: folder, manifest: manifest, localization: localization,
                                           dataFolder: FileManager.default.temporaryDirectory.appendingPathComponent("yab-data-\(UUID().uuidString)"),
                                           grant: grant(), urlSessionConfiguration: stub.configuration, log: sink.append)
        let context = context
        let call = Task { try await runtime.invoke(.run, name: "a", item: nil, context: context, effects: true, callID: 5) }
        let start = ContinuousClock.now
        while stub.requests.isEmpty, ContinuousClock.now - start < .seconds(3) { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        runtime.cancel(callID: 5)
        await #expect { _ = try await call.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        while stub.stops == 0, ContinuousClock.now - start < .seconds(3) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stub.stops == 1)
        let dir = sink.lines.first { $0.hasPrefix("dir ") }.map { String($0.dropFirst(4)) }
        #expect(dir != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.map { $0 + "/v.bin" } ?? "/nonexistent"))
    }

    /// A finished (not cancelled) fetch that listened to the call's signal lets go of the
    /// call, and of the runtime once nothing else holds it.
    @Test func aFinishedFetchLetsGoOfItsCallAndRuntime() async throws {
        stub.reset { _ in Self.ok() }
        let js = #"""
        exports.actions = { a: { async run(item, ctx) {
          const r = await yab.http.fetch("https://example.com/a", { signal: ctx.signal });
          const w = await fetch("https://example.com/a", { signal: ctx.signal });
          return { text: r.text + (await w.text()) };
        } } };
        """#
        weak var releasedScope: CallScope?
        weak var releasedRuntime: ExtensionRuntime?
        do {
            let runtime = try runtime(js)
            releasedRuntime = runtime
            let scope = CallScope(callID: 1, extensionID: runtime.extensionID, grant: runtime.grant, effects: true)
            releasedScope = scope
            #expect(try await runtime.call(.run, name: "a", arguments: [.null, .object([:])], in: scope) == .object(["text": .string("okok")]))
        }
        let start = ContinuousClock.now
        while releasedScope != nil || releasedRuntime != nil, ContinuousClock.now - start < .seconds(1) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(releasedScope == nil)
        #expect(releasedRuntime == nil)
    }

    @Test func networkFailuresNameTheHostNotTheURL() async throws {
        #expect(HTTPClient.map(URLError(.timedOut), host: "example.com") == ExtensionError(.networkError, "example.com: the request timed out"))
        #expect(HTTPClient.map(URLError(.cannotFindHost), host: "example.com").message == "example.com: the host was not found")
        #expect(HTTPClient.map(URLError(.cancelled), host: "example.com").code == .cancelled)
    }

    /// The host path (HostLoop/HostServer) hands a LoadRequest's grant to the runtime.
    @Test func theHostPassesTheLoadRequestsGrantToTheRuntime() async throws {
        let js = #"""
        exports.actions = { a: { async run() {
          try { await yab.http.fetch("https://example.com/"); return { text: "fetched" }; } catch (e) { return { text: e.code + ": " + e.message }; }
        } } };
        """#
        func ask(_ grant: PermissionGrant) throws -> String {
            let folder = try RuntimeFixture.folder(js: js)
            let pipe = Pipe()
            let collector = HostOutput()
            pipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData) }
            let server = HostServer(output: pipe.fileHandleForWriting)
            let encoder = JSONEncoder()
            let load = LoadRequest(extensionID: "dev.example.fixture", folder: folder.path,
                                   dataFolder: FileManager.default.temporaryDirectory.appendingPathComponent("yab-data-\(UUID().uuidString)").path,
                                   language: "en", grant: grant)
            server.handle(try encoder.encode(HostRequest(id: 1, load: load)))
            try collector.wait(for: { $0.contains { $0.id == 1 && $0.done == true } })
            server.handle(try encoder.encode(HostRequest(id: 2, invoke: InvokeRequest(extensionID: "dev.example.fixture", kind: .run, name: "a",
                                                                                         item: nil, context: context, effects: true))))
            try collector.wait(for: { $0.contains { $0.id == 2 && ($0.ok != nil || $0.error != nil) } })
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let message = collector.messages.first(where: { $0.id == 2 }) else { return "no answer" }
            if case .result(.text(let text)) = message.ok { return text }
            return message.error.map { "\($0.code.rawValue): \($0.message)" } ?? "unexpected"
        }
        #expect(try ask(.empty) == "permissionDenied: dev.example.fixture has no network permission")
        // With the grant the call gets past the permission and meets the domain rule (no request is made).
        #expect(try ask(grant(["video.example"])) == "permissionDenied: example.com is not in the extension's domains")
    }
}

/// Reads the host's output lines as messages.
final class HostOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let splitter = LineSplitter()
    private var all: [HostMessage] = []
    var messages: [HostMessage] { lock.withLock { all } }

    func append(_ data: Data) {
        let lines = lock.withLock { splitter.append(data) }
        let decoded = lines.compactMap { try? JSONDecoder().decode(HostMessage.self, from: $0) }
        lock.withLock { all.append(contentsOf: decoded) }
    }

    func wait(for condition: ([HostMessage]) -> Bool) throws {
        let start = ContinuousClock.now
        while !condition(messages) {
            if ContinuousClock.now - start > .seconds(5) { throw ExtensionError(.timeout, "the host did not answer") }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
