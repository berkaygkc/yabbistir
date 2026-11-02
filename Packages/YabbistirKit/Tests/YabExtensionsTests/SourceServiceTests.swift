import Foundation
import Testing
import YabCore
import YabExtensionKit
import YabLocalization
import YabPasteboard
@testable import YabExtensions

/// A synthetic extension with one source, "vault", in English and Turkish: a sensitive one has a secret action
/// (↵) and a text one (⇧↵, copied with ⌘C); one that is not has the text action alone.
enum SourceFixture {
    static func manifest(id: String, permissions: [String] = [], tools: [String] = [], sensitive: Bool = true) -> [String: Any] {
        var manifest = RegistryFixture.manifest(id: id, permissions: permissions)
        if !tools.isEmpty { manifest["requires"] = ["tools": tools.map { ["name": $0, "install": "brew install \($0)"] }] }
        let password: [String: Any] = ["id": "password", "kind": "secret", "title": "password.title", "label": "password.label"]
        let username: [String: Any] = ["id": "username", "kind": "text", "title": "username.title", "label": "username.label",
                                       "copyTitle": "username.copy", "copied": "username.copied"]
        manifest["contributes"] = [
            "actions": [["id": "a", "title": "name", "keywords": "keywords", "input": "none", "output": "text"]],
            "sources": [["id": "vault", "title": "vault.title", "sensitive": sensitive, "actions": sensitive ? [password, username] : [username]]],
        ]
        return manifest
    }

    static var locales: [String: [String: Any]] { [
        "en": ["name": "Vault", "keywords": ["k"], "upper": "Uppercase", "vault.title": "Vault", "password.title": "Paste password",
               "password.label": "Password", "username.title": "Paste username", "username.label": "Username",
               "username.copy": "Copy username", "username.copied": "Username copied."],
        "tr": ["name": "Kasa", "vault.title": "Kasa", "password.title": "Şifreyi yapıştır", "password.label": "Şifre",
               "username.title": "Kullanıcı adını yapıştır", "username.label": "Kullanıcı adı",
               "username.copy": "Kullanıcı adını kopyala", "username.copied": "Kullanıcı adı kopyalandı."],
    ] }

    @discardableResult
    static func write(in root: URL, id: String, permissions: [String] = [], tools: [String] = [], sensitive: Bool = true) throws -> URL {
        let folder = try RegistryFixture.write(in: root, id: id, manifest: manifest(id: id, permissions: permissions, tools: tools, sensitive: sensitive))
        for (language, table) in locales {
            try JSONSerialization.data(withJSONObject: table).write(to: folder.appendingPathComponent("locales/\(language).json"))
        }
        return folder
    }

    /// A host that loads anything, lists two rows and gives each action a value of its kind.
    static func transport() -> FakeTransport {
        FakeTransport { request in
            guard let invoke = request.invoke else { return HostMessage(id: request.id, done: true) }
            switch invoke.kind {
            case .sourceList:
                return HostMessage(id: request.id, ok: .listing(.rows([SourceRow(id: "42", title: "ornek.dev", subtitle: "deniz.k"),
                                                                       SourceRow(id: "7", title: "Kasa", subtitle: nil)])))
            case .sourceRun:
                return HostMessage(id: request.id, ok: .value(invoke.source?.kind == .secret ? .secret("s3cr3t-örnek") : .text("deniz.k")))
            default:
                return HostMessage(id: request.id, ok: .result(.text("ok")))
            }
        }
    }
}

/// A transport that loads at once and holds every invoke until the test answers it.
final class HeldTransport: HostTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var onLine: (@Sendable (Data) -> Void)?
    private var sent: [HostRequest] = []
    private var restartCount = 0

    var requests: [HostRequest] { lock.withLock { sent } }
    var restarts: Int { lock.withLock { restartCount } }

    func start(onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) throws { lock.withLock { self.onLine = onLine } }

    func send(_ line: Data) {
        guard let request = try? JSONDecoder().decode(HostRequest.self, from: line) else { return }
        lock.withLock { sent.append(request) }
        if request.load != nil { answer(HostMessage(id: request.id, done: true)) }
    }

    func answer(_ message: HostMessage) {
        let handler = lock.withLock { onLine }
        guard let data = try? JSONEncoder().encode(message) else { return }
        DispatchQueue.global().async { handler?(data) }
    }

    func restart() throws { lock.withLock { restartCount += 1 } }
    func stop() {}
}

@MainActor @Suite struct SourceServiceTests {
    let library: Library
    let builtIn = RegistryFixture.temporary("BuiltinExtensions")
    let user = RegistryFixture.temporary("Extensions")
    let settings = ExtensionSettings(defaults: UserDefaults(suiteName: "yab-src-\(UUID().uuidString)")!)
    let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-src-lang-\(UUID().uuidString)")!)
    static let key = "dev.example.vault/vault"

    init() throws {
        library = try Library(store: ItemStore.temporary())
        language.language = .turkish
    }

    /// The extensions are in place before the registry starts watching, so no reload comes in the middle of a test.
    func service(transport: FakeTransport = SourceFixture.transport(), toolSearchPath: [String] = [], resultFiles: ResultFiles? = nil,
                 sourceTimeout: Duration = .seconds(10), log: @escaping (String, String) -> Void = { _, _ in }) -> ExtensionService {
        let registry = ExtensionRegistry(builtInRoot: builtIn, userRoot: user, dataRoot: RegistryFixture.temporary("Data"), settings: settings)
        return ExtensionService(registry: registry, client: ExtensionHostClient(transport: transport, onLog: log), library: library,
                                settings: settings, language: language, toolSearchPath: toolSearchPath, resultFiles: resultFiles,
                                sourceTimeouts: (sourceTimeout, sourceTimeout))
    }

    @Test func sourcesComeFromUsableExtensionsOnly() throws {
        try SourceFixture.write(in: user, id: "dev.example.vault")
        try SourceFixture.write(in: user, id: "dev.example.off")
        settings.setEnabled("dev.example.off", false)
        // Asks to run a program and nobody has approved that yet.
        try SourceFixture.write(in: user, id: "dev.example.asking", permissions: ["exec"], tools: ["vault-cli"])
        let service = service()
        #expect(service.registry.installed.count == 3)
        #expect(service.sources.map(\.id) == [Self.key])
        service.registry.approveRequested("dev.example.asking")
        #expect(service.sources.map(\.id).sorted() == ["dev.example.asking/vault", Self.key])
    }

    /// Everything the panel draws for a source comes from its manifest, in the app's language.
    @Test func aSourceIsDescribedInTheAppsLanguage() throws {
        try SourceFixture.write(in: user, id: "dev.example.vault")
        let service = service()
        let vault = try #require(service.sources.first)
        #expect(vault.extensionID == "dev.example.vault" && vault.sourceID == "vault")
        #expect(vault.extensionName == "Kasa" && vault.title == "Kasa" && vault.sensitive)
        #expect(vault.primary == SourceActionDescriptor(id: "password", kind: .secret, title: "Şifreyi yapıştır", label: "Şifre"))
        #expect(vault.alternate == SourceActionDescriptor(id: "username", kind: .text, title: "Kullanıcı adını yapıştır", label: "Kullanıcı adı",
                                                          copyTitle: "Kullanıcı adını kopyala", copied: "Kullanıcı adı kopyalandı."))
        #expect(vault.copyAction?.id == "username")
        #expect(vault.secretLabel == "Şifre")
        language.language = .english
        #expect(service.sources.first?.title == "Vault")
        #expect(service.sources.first?.primary.title == "Paste password")
    }

    /// A source without a secret action: ↵ is its text action, and there is nothing to hide.
    @Test func aTextOnlySourceHasNoSecretLabel() throws {
        try SourceFixture.write(in: user, id: "dev.example.vault", sensitive: false)
        let vault = try #require(service().sources.first)
        #expect(!vault.sensitive)
        #expect(vault.primary.id == "username" && vault.alternate == nil)
        #expect(vault.copyAction?.id == "username")
        #expect(vault.secretLabel == nil)
    }

    @Test func listingASourceRunsItWithEffects() async throws {
        try SourceFixture.write(in: user, id: "dev.example.vault")
        let transport = SourceFixture.transport()
        let service = service(transport: transport)
        let listing = try await service.list(source: Self.key)
        #expect(listing == .rows([SourceRow(id: "42", title: "ornek.dev", subtitle: "deniz.k"), SourceRow(id: "7", title: "Kasa")]))
        let invoke = try #require(transport.requests.compactMap(\.invoke).first)
        #expect(invoke.kind == .sourceList && invoke.name == "vault" && invoke.extensionID == "dev.example.vault")
        #expect(invoke.effects)
        #expect(invoke.context.trigger == .source)
        #expect(invoke.item == nil && invoke.source == nil)
    }

    @Test func runPassesTheRowTheActionAndItsKind() async throws {
        try SourceFixture.write(in: user, id: "dev.example.vault")
        let transport = SourceFixture.transport()
        let service = service(transport: transport)
        #expect(try await service.run(source: Self.key, row: "42", action: "password") == .secret("s3cr3t-örnek"))
        #expect(try await service.run(source: Self.key, row: "7", action: "username") == .text("deniz.k"))
        let invokes = transport.requests.compactMap(\.invoke)
        #expect(invokes.map(\.kind) == [.sourceRun, .sourceRun])
        #expect(invokes.map(\.source) == [SourceInvocation(rowID: "42", actionID: "password", kind: .secret),
                                          SourceInvocation(rowID: "7", actionID: "username", kind: .text)])
        #expect(invokes.allSatisfy { $0.effects && $0.context.trigger == .source && $0.name == "vault" && $0.item == nil })
    }

    /// The values a source gives go to the caller alone: history, the panel session's outputs, Outputs and the log never see them.
    @Test func aSourceValueNeverReachesHistoryOrOutputs() async throws {
        try SourceFixture.write(in: user, id: "dev.example.vault")
        let files = ResultFiles(root: RegistryFixture.temporary("Outputs"), workRoot: RegistryFixture.temporary("Work"))
        var lines: [String] = []
        let service = service(resultFiles: files) { id, line in lines.append("\(id) \(line)") }
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("merhaba".utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        library.didIngest(try #require(try library.store.ingest(clip)).item)
        let before = try library.store.itemIDs(after: nil, limit: 100)
        let command = try #require(service.catalog.commands.first { $0.extensionID == "dev.example.vault" })

        _ = try await service.list(source: Self.key)
        #expect(try await service.run(source: Self.key, row: "42", action: "password") == .secret("s3cr3t-örnek"))
        #expect(try await service.run(source: Self.key, row: "42", action: "username") == .text("deniz.k"))

        #expect(try library.store.itemIDs(after: nil, limit: 100) == before)
        #expect(library.index.search("s3cr3t", limit: 10).ids.isEmpty)
        #expect(service.cachedOutput(of: command, subjectID: nil) == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: files.root.path)) ?? [] == [])
        #expect((try? FileManager.default.contentsOfDirectory(atPath: files.workRoot.path)) ?? [] == [])
        #expect(!lines.contains { $0.contains("s3cr3t") || $0.contains("deniz.k") || $0.contains("ornek.dev") })
    }

    /// The helper holds a value to its action's kind; the app does too, so a secret never passes as text (text is not
    /// concealed on the clipboard).
    @Test func aValueOfTheWrongKindIsABadResult() async throws {
        try SourceFixture.write(in: user, id: "dev.example.vault")
        let transport = FakeTransport { request in
            guard request.invoke != nil else { return HostMessage(id: request.id, done: true) }
            return HostMessage(id: request.id, ok: .value(.text("s3cr3t-örnek")))
        }
        let service = service(transport: transport)
        let error = await #expect(throws: ExtensionError.self) { _ = try await service.run(source: Self.key, row: "42", action: "password") }
        #expect(error?.code == .badResult)
        #expect(error?.message.contains("s3cr3t") == false)
    }

    /// A source that needs a program the Mac lacks says how to get it, before anything reaches the helper.
    @Test func aMissingToolFailsBeforeTheHelper() async throws {
        try SourceFixture.write(in: user, id: "dev.example.vault", permissions: ["exec"], tools: ["vault-cli"])
        let transport = SourceFixture.transport()
        let service = service(transport: transport, toolSearchPath: [RegistryFixture.temporary("bin").path])
        service.registry.approveRequested("dev.example.vault")
        let error = await #expect(throws: ExtensionError.self) { _ = try await service.list(source: Self.key) }
        #expect(error?.code == .toolMissing)
        #expect(error?.message == "vault-cli is not installed. Install it with: brew install vault-cli")
        #expect(transport.requests.isEmpty)
    }

    /// A vault whose tool hangs at every open (a prompt nobody answers) runs out of time each time: its extension stays
    /// on, the host is never restarted for it, and the panel keeps the rows it had.
    @Test func threeSourceTimeoutsLeaveTheExtensionOn() async throws {
        try SourceFixture.write(in: user, id: "dev.example.vault")
        let lists = Counter()
        let transport = FakeTransport { request in
            guard let invoke = request.invoke else { return request.load != nil ? HostMessage(id: request.id, done: true) : nil }
            // The first list answers; every one after it hangs.
            guard invoke.kind == .sourceList, lists.next() == 0 else { return nil }
            return HostMessage(id: request.id, ok: .listing(.rows([SourceRow(id: "42", title: "ornek.dev", subtitle: "deniz.k")])))
        }
        let service = service(transport: transport, sourceTimeout: .milliseconds(50))
        let center = SourceCenter(service: service)
        let rows = SourceCenter.State.rows([SourceRow(id: "42", title: "ornek.dev", subtitle: "deniz.k")])
        center.refresh([Self.key])
        await center.call(for: Self.key)?.value
        #expect(center.state(of: Self.key) == rows)
        for _ in 0..<3 {
            center.refresh([Self.key])
            await center.call(for: Self.key)?.value
        }
        #expect(center.state(of: Self.key) == rows)
        #expect(transport.restarts == 0)
        #expect(!service.client.isDisabled("dev.example.vault"))
        #expect(settings.isEnabled("dev.example.vault"))
        #expect(service.registry.installed.first { $0.id == "dev.example.vault" }?.isUsable == true)
        #expect(service.sources.map(\.id) == [Self.key])
        // Each hung list was aborted in the helper, the call alone.
        let hung = transport.requests.filter { $0.invoke?.kind == .sourceList }.dropFirst().map(\.id)
        try await eventually { Set(transport.requests.compactMap(\.cancel?.callID)) == Set(hung) }
    }

    /// A source's call that runs out of time is aborted in the helper (its signal fires, its tool stops); a call of
    /// the same extension on its way meanwhile goes on and answers.
    @Test func aSourceTimeoutCancelsTheCall() async throws {
        let transport = HeldTransport()
        let client = ExtensionHostClient(transport: transport) { _, _ in }
        let search = ExtensionContext(language: "tr", trigger: .search)
        let run = Task { try await client.invoke("dev.example.vault", .run, name: "a", item: nil, context: search, effects: true, timeout: nil) }
        try await eventually { transport.requests.contains { $0.invoke?.kind == .run } }
        let error = await #expect(throws: ExtensionError.self) {
            _ = try await client.invoke("dev.example.vault", .sourceList, name: "vault", item: nil,
                                        context: ExtensionContext(language: "tr", trigger: .source), effects: true, timeout: .milliseconds(50))
        }
        #expect(error?.code == .timeout)
        let list = try #require(transport.requests.first { $0.invoke?.kind == .sourceList })
        try await eventually { transport.requests.contains { $0.cancel?.callID == list.id } }
        #expect(transport.restarts == 0)
        let held = try #require(transport.requests.first { $0.invoke?.kind == .run })
        #expect(!transport.requests.contains { $0.cancel?.callID == held.id })
        transport.answer(HostMessage(id: held.id, ok: .result(.text("ok"))))
        #expect(try await run.value == .result(.text("ok")))
        #expect(!client.isDisabled("dev.example.vault"))
    }

    @Test func anUnknownSourceOrActionIsNotFound() async throws {
        try SourceFixture.write(in: user, id: "dev.example.vault")
        let transport = SourceFixture.transport()
        let service = service(transport: transport)
        await #expect { _ = try await service.list(source: "dev.example.vault/other") } throws: { ($0 as? ExtensionError)?.code == .notFound }
        await #expect { _ = try await service.run(source: Self.key, row: "42", action: "otp") } throws: { ($0 as? ExtensionError)?.code == .notFound }
        #expect(transport.requests.compactMap(\.invoke).isEmpty)
    }
}
