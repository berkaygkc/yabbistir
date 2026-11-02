import Foundation
import Testing
import YabExtensionKit
@testable import YabExtensions

/// Sources whose lists answer only when a test says so.
@MainActor final class FakeSourceService: SourceServing {
    var sources: [SourceDescriptor]
    /// Every list that reached the service, in order.
    private(set) var asked: [String] = []
    private(set) var runs: [String] = []
    private var waiting: [(key: String, answer: CheckedContinuation<Result<SourceListing, ExtensionError>, Never>)] = []
    private var arrivals: [(key: String, arrived: CheckedContinuation<Void, Never>)] = []

    init(keys: [String]) {
        sources = keys.map { key in
            let parts = key.split(separator: "/").map(String.init)
            return SourceDescriptor(extensionID: parts[0], extensionName: "Kasa", sourceID: parts[1], title: "Kasa", sensitive: true,
                                    actions: [SourceActionDescriptor(id: "password", kind: .secret, title: "Şifreyi yapıştır", label: "Şifre")])
        }
    }

    func list(source key: String) async throws(ExtensionError) -> SourceListing {
        asked.append(key)
        let result = await withCheckedContinuation { continuation in
            waiting.append((key, continuation))
            let arrived = arrivals.filter { $0.key == key }
            arrivals.removeAll { $0.key == key }
            for arrival in arrived { arrival.arrived.resume() }
        }
        return try result.get()
    }

    func run(source key: String, row: String, action: String) async throws(ExtensionError) -> SourceValue {
        runs.append("\(key) \(row) \(action)")
        return .secret("s3cr3t-örnek")
    }

    /// Returns once a list of `key` is waiting for its answer (the center's call starts on a later turn).
    func arrival(of key: String) async {
        guard !waiting.contains(where: { $0.key == key }) else { return }
        await withCheckedContinuation { arrivals.append((key, $0)) }
    }

    /// Answers the oldest list waiting for `key`, once there is one.
    func answer(_ key: String, _ result: Result<SourceListing, ExtensionError>) async {
        await arrival(of: key)
        guard let index = waiting.firstIndex(where: { $0.key == key }) else { Issue.record("no list of \(key) is waiting"); return }
        waiting.remove(at: index).answer.resume(returning: result)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SourceCenterTests {
    static let vault = "dev.example.vault/vault"
    static let notes = "dev.example.notes/notes"
    let service = FakeSourceService(keys: [Self.vault, Self.notes])
    let center: SourceCenter
    let rows = [SourceRow(id: "42", title: "ornek.dev", subtitle: "deniz.k")]
    let newer = [SourceRow(id: "42", title: "ornek.dev", subtitle: "deniz.k"), SourceRow(id: "7", title: "Kasa")]

    init() {
        center = SourceCenter(service: service)
    }

    /// Lets the call on its way for `key` answer, and waits until the center has taken the answer in.
    func answer(_ key: String, _ result: Result<SourceListing, ExtensionError>) async throws {
        let call = try #require(center.call(for: key))
        await service.answer(key, result)
        await call.value
    }

    /// `key` shows `rows`, from a call that has ended.
    func filled(_ key: String, with rows: [SourceRow]) async throws {
        center.refresh([key])
        try await answer(key, .success(.rows(rows)))
        #expect(center.state(of: key) == .rows(rows))
    }

    @Test func refreshKeepsTheLastRowsUntilTheAnswer() async throws {
        var changes = 0
        center.onChange = { changes += 1 }
        #expect(center.state(of: Self.vault) == .idle)
        center.refresh([Self.vault])
        #expect(center.state(of: Self.vault) == .loading)
        try await answer(Self.vault, .success(.rows(rows)))
        #expect(center.state(of: Self.vault) == .rows(rows))
        #expect(changes == 1)
        // Shown at once on the next open, while the new list is on its way.
        center.refresh([Self.vault])
        #expect(center.state(of: Self.vault) == .rows(rows))
        try await answer(Self.vault, .success(.rows(newer)))
        #expect(center.state(of: Self.vault) == .rows(newer))
        #expect(changes == 2)
    }

    @Test func aLockedAnswerClearsTheRowsAtOnce() async throws {
        try await filled(Self.vault, with: rows)
        center.refresh([Self.vault])
        try await answer(Self.vault, .success(.locked(message: "Kasa kilitli", command: "vault login deniz.k")))
        #expect(center.state(of: Self.vault) == .locked(message: "Kasa kilitli", command: "vault login deniz.k"))
    }

    @Test func oneCallPerSourceAtATime() async throws {
        center.refresh([Self.vault])
        let first = try #require(center.call(for: Self.vault))
        center.refresh([Self.vault, Self.notes])
        center.refresh([Self.vault])
        #expect(center.call(for: Self.vault) == first)
        await service.arrival(of: Self.vault)
        await service.arrival(of: Self.notes)
        #expect(service.asked == [Self.vault, Self.notes])
        try await answer(Self.vault, .success(.rows(rows)))
        center.refresh([Self.vault, Self.notes])
        #expect(center.call(for: Self.vault) != first)
        await service.arrival(of: Self.vault)
        #expect(service.asked == [Self.vault, Self.notes, Self.vault])
        try await answer(Self.vault, .success(.rows(newer)))
        try await answer(Self.notes, .success(.rows(rows)))
        #expect(service.asked == [Self.vault, Self.notes, Self.vault])
    }

    /// The Mac locked: every row goes, and a list that answers afterwards brings none back.
    @Test func clearAllForgetsEveryRow() async throws {
        try await filled(Self.vault, with: rows)
        center.refresh([Self.notes])
        let late = try #require(center.call(for: Self.notes))
        var changes = 0
        center.onChange = { changes += 1 }
        center.clearAll()
        #expect(center.state(of: Self.vault) == .idle)
        #expect(center.state(of: Self.notes) == .idle)
        #expect(center.call(for: Self.notes) == nil)
        #expect(changes == 1)
        await service.answer(Self.notes, .success(.rows(rows)))
        await late.value
        #expect(center.state(of: Self.notes) == .idle)
        #expect(changes == 1)
        // The next open asks again.
        center.refresh([Self.vault, Self.notes])
        #expect(center.state(of: Self.vault) == .loading)
        try await answer(Self.vault, .success(.rows(newer)))
        try await answer(Self.notes, .success(.rows(newer)))
        #expect(center.state(of: Self.notes) == .rows(newer))
        #expect(service.asked == [Self.vault, Self.notes, Self.vault, Self.notes])
    }

    @Test func aFailureWithoutRowsShowsTheMessage() async throws {
        center.refresh([Self.vault])
        try await answer(Self.vault, .failure(ExtensionError(.toolMissing, "vault-cli is not installed")))
        #expect(center.state(of: Self.vault) == .failed("vault-cli is not installed"))
    }

    /// A failure is shown until the next answer replaces it: asking again does not blank it to "loading".
    @Test func aFailureStaysUntilTheNextAnswer() async throws {
        center.refresh([Self.vault])
        try await answer(Self.vault, .failure(ExtensionError(.toolMissing, "vault-cli is not installed")))
        center.refresh([Self.vault])
        #expect(center.state(of: Self.vault) == .failed("vault-cli is not installed"))
        try await answer(Self.vault, .success(.rows(rows)))
        #expect(center.state(of: Self.vault) == .rows(rows))
    }

    /// A vault whose session ran out stays locked from one open to the next: its row stays put while it is asked again.
    @Test func aLockedRowStaysWhileRefreshing() async throws {
        let locked = SourceListing.locked(message: "Kasa kilitli", command: "vault login deniz.k")
        center.refresh([Self.vault])
        try await answer(Self.vault, .success(locked))
        var changes = 0
        center.onChange = { changes += 1 }
        center.refresh([Self.vault])
        #expect(center.state(of: Self.vault) == .locked(message: "Kasa kilitli", command: "vault login deniz.k"))
        try await answer(Self.vault, .success(locked))
        #expect(center.state(of: Self.vault) == .locked(message: "Kasa kilitli", command: "vault login deniz.k"))
        #expect(changes == 0)
        // Unlocked in Terminal: the rows replace it on the next open.
        center.refresh([Self.vault])
        try await answer(Self.vault, .success(.rows(rows)))
        #expect(center.state(of: Self.vault) == .rows(rows))
        #expect(changes == 1)
    }

    /// A slow or failing list (a timeout, the helper restarting) never spoils the rows already shown.
    @Test func aFailureKeepsTheLastRows() async throws {
        try await filled(Self.vault, with: rows)
        var changes = 0
        center.onChange = { changes += 1 }
        center.refresh([Self.vault])
        try await answer(Self.vault, .failure(ExtensionError(.timeout, "the extension did not answer in time")))
        #expect(center.state(of: Self.vault) == .rows(rows))
        #expect(changes == 0)
    }

    /// An extension turned off or removed takes its source's rows with it, also a list still on its way.
    @Test func aGoneSourceIsForgotten() async throws {
        try await filled(Self.vault, with: rows)
        try await filled(Self.notes, with: rows)
        center.refresh([Self.vault])
        let late = try #require(center.call(for: Self.vault))
        var changes = 0
        center.onChange = { changes += 1 }
        service.sources.removeAll { $0.id == Self.vault }
        center.sourcesChanged()
        #expect(center.descriptors.map(\.id) == [Self.notes])
        #expect(center.state(of: Self.vault) == .idle)
        #expect(center.state(of: Self.notes) == .rows(rows))
        #expect(changes == 1)
        await service.answer(Self.vault, .success(.rows(newer)))
        await late.value
        #expect(center.state(of: Self.vault) == .idle)
        // Nothing gone: nothing changes.
        center.sourcesChanged()
        #expect(changes == 1)
        // A key no source has is not asked for.
        center.refresh([Self.vault])
        #expect(center.call(for: Self.vault) == nil)
        #expect(center.state(of: Self.vault) == .idle)
    }

    /// A row action goes to the extension as it is; its value is handed back and kept nowhere.
    @Test func aRunGoesStraightToTheService() async throws {
        try await filled(Self.vault, with: rows)
        #expect(try await center.run(Self.vault, row: "42", action: "password") == .secret("s3cr3t-örnek"))
        #expect(service.runs == ["\(Self.vault) 42 password"])
        #expect(center.state(of: Self.vault) == .rows(rows))
    }
}
