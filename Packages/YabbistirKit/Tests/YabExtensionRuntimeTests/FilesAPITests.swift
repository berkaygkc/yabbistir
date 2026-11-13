import Foundation
import Testing
import YabExtensionKit
import YabTestSupport
@testable import YabExtensionRuntime

@Suite struct FilesAPITests {
    let context = ExtensionContext(language: "en", trigger: .search)

    func run(_ js: String, item: ExtensionItem? = nil) async throws -> InvokeOutput {
        try await RuntimeFixture.load(js: js).invoke(.run, name: "a", item: item, context: context)
    }

    func refused(_ js: String, item: ExtensionItem? = nil) async -> ExtensionError? {
        do {
            _ = try await run(js, item: item)
            return nil
        } catch let error as ExtensionError {
            return error
        } catch {
            return ExtensionError(.script, "\(error)")
        }
    }

    /// The call's work folder lives in the shared temporary folder, one folder per call.
    @Test func filesWrittenByAnExtensionComeBack() async throws {
        let js = #"""
        exports.actions = { a: { run() {
          const path = yab.files.write("not.txt", "merhaba");
          const bytes = yab.files.read(path);
          if (new TextDecoder().decode(bytes) !== "merhaba" || !yab.files.exists(path)) return { text: "bad" };
          return { file: path };
        } } };
        """#
        guard case .result(.file(let path)) = try await run(js) else { Issue.record("expected a file result"); return }
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        #expect(URL(fileURLWithPath: path).lastPathComponent == "not.txt")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "merhaba")
        let work = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath()
        #expect(work.deletingLastPathComponent() == WorkFolders.root.resolvingSymlinksInPath())
    }

    @Test func aResultOutsideTheWorkFolderIsRefused() async throws {
        for js in [#"exports.actions = { a: { run: () => ({ file: "/etc/hosts" }) } };"#,
                   #"exports.actions = { a: { run: () => ({ files: [yab.files.write("a.txt", "x"), "/etc/hosts"] }) } };"#,
                   #"exports.actions = { a: { run: () => ({ file: yab.files.workDir + "/../../../etc/hosts" }) } };"#,
                   #"exports.actions = { a: { run: () => ({ file: "/etc/hosts" }) } };"#] {
            #expect(await refused(js)?.code == .badResult)
        }
    }

    @Test func aSymlinkOutOfTheWorkFolderIsRefused() async throws {
        let outside = TestScratch.url("yab-outside", pathExtension: "txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let js = """
        exports.actions = { a: { run() {
          const dir = yab.files.workDir;
          yab.files.write("keep.txt", "x");
          return { file: dir + "/link" };
        } } };
        """
        // The script cannot make links itself, so a hand-made one stands in for a tool that did.
        let probe: @convention(block) (String) -> Void = { dir in
            try? FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: outside.path)
        }
        let linking = js.replacingOccurrences(of: #"yab.files.write("keep.txt", "x");"#, with: "link(dir);")
        let linked = try RuntimeFixture.load(js: linking)
        linked.queue.sync { linked.context.setObject(unsafeBitCast(probe, to: AnyObject.self), forKeyedSubscript: "link" as NSString) }
        do {
            _ = try await linked.invoke(.run, name: "a", item: nil, context: context)
            Issue.record("a link out of the folder was accepted")
        } catch {
            #expect(error.code == .badResult)
        }
    }

    @Test func namesCannotLeaveTheWorkFolder() async throws {
        for name in ["../x", "..", "", String(repeating: "a", count: 201), "a/../../b", ".", ".. ", "..\n", " . "] {
            let literal = String(data: try JSONEncoder().encode(name), encoding: .utf8)!
            #expect(await refused("exports.actions = { a: { run: () => ({ file: yab.files.write(\(literal), \"x\") }) } };")?.code == .badResult,
                    "name \(name.prefix(12))")
        }
        // Slashes and colons that stay inside a name become dashes.
        guard case .result(.file(let path)) = try await run(#"exports.actions = { a: { run: () => ({ file: yab.files.write("a:b/c.txt", "x") }) } };"#)
        else { Issue.record("expected a file"); return }
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        #expect(URL(fileURLWithPath: path).lastPathComponent == "a-b-c.txt")
    }

    @Test func readingIsLimitedToTheWorkFolderAndTheItemsFiles() async throws {
        let own = TestScratch.url("yab-own", pathExtension: "txt")
        try "own".write(to: own, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: own) }
        let item = ExtensionItem(id: 1, kind: "file", files: [.init(path: own.path, name: own.lastPathComponent, size: 3, uti: "public.text")],
                                 copiedAt: Date())
        let js = #"""
        exports.actions = { a: { run(item) {
          const seen = [new TextDecoder().decode(yab.files.read(item.files[0].path))];
          for (const p of ["/etc/hosts", yab.files.workDir + "/../../../../etc/hosts"]) {
            try { yab.files.read(p); seen.push("read"); } catch (e) { seen.push(e.code); }
            seen.push(yab.files.exists(p));
          }
          return { text: seen.join("|") };
        } } };
        """#
        guard case .result(.text(let text)) = try await run(js, item: item) else { Issue.record("expected text"); return }
        #expect(text == "own|badResult|false|badResult|false")
    }

    @Test func workFoldersAreRemoved() async throws {
        // A call with no file result: its folder is gone once the call is.
        guard case .result(.text(let dir)) = try await run(#"exports.actions = { a: { run() { yab.files.write("x.txt", "x"); return { text: yab.files.workDir }; } } };"#)
        else { Issue.record("expected text"); return }
        #expect(dir.hasPrefix(WorkFolders.root.path))
        #expect(!FileManager.default.fileExists(atPath: dir))
        // A call that fails, too.
        let sink = LogSink()
        let failing = try RuntimeFixture.load(js: #"exports.actions = { a: { run() { yab.files.write("x.txt", "x"); console.log(yab.files.workDir); throw new Error("no"); } } };"#,
                                              log: sink.append)
        await #expect { _ = try await failing.invoke(.run, name: "a", item: nil, context: context) } throws: { ($0 as? ExtensionError)?.code == .script }
        #expect(!FileManager.default.fileExists(atPath: try #require(sink.lines.first)))
        // A call that returns a file keeps its folder for the app to adopt.
        guard case .result(.file(let path)) = try await run(#"exports.actions = { a: { run: () => ({ file: yab.files.write("k.txt", "x") }) } };"#)
        else { Issue.record("expected a file"); return }
        let kept = URL(fileURLWithPath: path).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: path))
        try FileManager.default.removeItem(at: kept)
    }

    @Test func aCancelledCallsFolderIsRemoved() async throws {
        let sink = LogSink()
        let js = #"""
        exports.actions = { a: { async run() {
          yab.files.write("x.txt", "x");
          console.log(yab.files.workDir);
          await new Promise(() => {});
        } } };
        """#
        let runtime = try RuntimeFixture.load(js: js, log: sink.append)
        let context = context
        let call = Task { try await runtime.invoke(.run, name: "a", item: nil, context: context, callID: 9) }
        let start = ContinuousClock.now
        while sink.lines.isEmpty, ContinuousClock.now - start < .seconds(3) { try await Task.sleep(for: .milliseconds(10)) }
        let dir = try #require(sink.lines.first)
        #expect(FileManager.default.fileExists(atPath: dir))
        runtime.cancel(callID: 9)
        await #expect { _ = try await call.value } throws: { ($0 as? ExtensionError)?.code == .cancelled }
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test func anImageHandleIsWrittenAsPNG() async throws {
        let item = TestImages.item(TestImages.photo(width: 20, height: 10))
        guard case .result(.file(let path)) = try await run(#"exports.actions = { a: { run: (item) => ({ file: yab.files.write("a.png", item.image) }) } };"#, item: item)
        else { Issue.record("expected a file"); return }
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    @Test func bytesAreWrittenAsTheyAre() async throws {
        guard case .result(.file(let path)) = try await run(#"exports.actions = { a: { run: () => ({ file: yab.files.write("b.bin", new Uint8Array([0, 1, 255])) }) } };"#)
        else { Issue.record("expected a file"); return }
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([0, 1, 255]))
    }
}
