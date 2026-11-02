import AppKit
import SwiftUI
import Testing
import YabCore
import YabImport
import YabLocalization
@testable import YabUI

/// Renders the first-run steps to PNG for visual review, from synthetic data (no library is read). Off by default;
/// run with `TEST_RUNNER_YAB_SNAPSHOT_DIR=/some/dir make test ONLY=YabUITests/OnboardingSnapshot`.
@MainActor @Suite struct OnboardingSnapshot {
    static let dir = ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]

    /// A sample library: six pinboards, 1,355 items in all, 130 MB.
    static let summary = PasteSummary(historyCount: 1_115, boards: [
        PasteBoard(id: 1, name: "SQL", count: 42), PasteBoard(id: 2, name: "Linkler", count: 88),
        PasteBoard(id: 3, name: "Müşteri yanıtları", count: 17), PasteBoard(id: 4, name: "Renkler", count: 9),
        PasteBoard(id: 5, name: "Komutlar", count: 23), PasteBoard(id: 6, name: "Eski projeler", count: 61),
    ], totalBytes: 130_000_000)
    static let location = PasteLibraryLocation(
        folder: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/com.example.library"),
        vendor: "Ornek")
    static let kinds: [ItemKind: Int] = [.text: 612, .code: 301, .link: 248, .image: 121, .color: 39, .file: 34]

    private final class Flags {
        var trusted = false
        var running = false
    }

    private func make(_ state: ImportModel.State, language: AppLanguage = .turkish, trusted: Bool = false,
                      running: Bool = false) throws -> (OnboardingModel, ImportModel) {
        let languages = LanguageStore(defaults: UserDefaults(suiteName: "snap-onb-\(UUID())")!)
        languages.language = language
        let flags = Flags()
        flags.trusted = trusted
        flags.running = running
        let importer = ImportModel(store: try ItemStore.temporary(), reload: {}, ignoredApps: { [] }, locate: { nil },
                                   otherAppRunning: { flags.running }, quitOtherApp: {}, language: languages)
        importer.state = state
        // As a scan leaves it: everything chosen.
        if case .ready(let summary, _) = state {
            importer.selection = PasteSelection(history: true, boards: Set(summary.boards.map(\.id)))
        }
        let model = OnboardingModel(
            importer: importer, preferences: Preferences(defaults: UserDefaults(suiteName: "snap-onb-p-\(UUID())")!),
            language: languages, loginItem: FakeLoginItem(), isTrusted: { flags.trusted }, promptAccessibility: {},
            onFinish: {})
        return (model, importer)
    }

    /// Drawn through AppKit at 2× in an offscreen window, on a neutral backdrop so the corners and the rim show.
    private func write(_ model: OnboardingModel, _ name: String, appearance: NSAppearance.Name = .aqua) throws {
        let dir = URL(fileURLWithPath: try #require(Self.dir), isDirectory: true).appendingPathComponent("onboarding-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var view = OnboardingView(model: model)
        view.snapshot = true
        let dark = appearance == .darkAqua
        let backdrop = ZStack {
            (dark ? Color(white: 0.16) : Color(white: 0.84))
            view.padding(32)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: backdrop.fixedSize())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderWelcome() throws {
        let (model, _) = try make(.ready(Self.summary, Self.location))
        try write(model, "1-welcome")
        let (english, _) = try make(.ready(Self.summary, Self.location), language: .english)
        try write(english, "1-welcome-en")
        let (bare, _) = try make(.unavailable)
        try write(bare, "1-welcome-no-library")
        let (dark, _) = try make(.ready(Self.summary, Self.location))
        try write(dark, "1-welcome-dark", appearance: .darkAqua)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderImportChoice() throws {
        let (model, _) = try make(.ready(Self.summary, Self.location))
        model.next()
        try #require(model.step == .importChoice)
        try write(model, "2-import-choice")
        let (english, _) = try make(.ready(Self.summary, Self.location), language: .english)
        english.next()
        try write(english, "2-import-choice-en", appearance: .darkAqua)
        let (scanning, importer) = try make(.ready(Self.summary, Self.location))
        scanning.next()
        importer.state = .scanning
        try write(scanning, "2-import-choice-scanning")
        let many = PasteSummary(historyCount: 900, boards: (1...11).map { PasteBoard(id: Int64($0), name: "Pinboard \($0)", count: $0 * 7) },
                                totalBytes: 48_000_000)
        let (crowded, _) = try make(.ready(many, Self.location))
        crowded.next()
        try write(crowded, "2-import-choice-many-boards")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderImporting() async throws {
        var report = ImportReport()
        report.added = 1_355
        report.kinds = Self.kinds
        let (model, importer) = try make(.ready(Self.summary, Self.location))
        model.next()
        model.next()
        // The synthetic location holds no library: let that run end, then show the finished state.
        await importer.finished()
        try #require(model.step == .importing)
        importer.state = .done(report)
        try write(model, "3-importing-done")

        let (running, runningImporter) = try make(.ready(Self.summary, Self.location))
        running.next()
        running.next()
        await runningImporter.finished()
        runningImporter.state = .importing(ImportProgress(
            done: 610, total: 1_355, kinds: Self.kinds.mapValues { $0 * 610 / 1_355 }))
        try write(running, "3-importing-progress")

        var partial = report
        partial.added = 1_352
        partial.failed = 3
        let (failing, failingImporter) = try make(.ready(Self.summary, Self.location))
        failing.next()
        failing.next()
        await failingImporter.finished()
        failingImporter.state = .done(partial)
        try write(failing, "3-importing-some-failed")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderSetup() throws {
        let (model, _) = try make(.ready(Self.summary, Self.location))
        model.next()
        model.skipImport()
        try #require(model.step == .setup)
        try write(model, "4-setup")
        let (granted, _) = try make(.ready(Self.summary, Self.location), trusted: true, running: true)
        granted.skipImport()
        try write(granted, "4-setup-granted-other-app-running")
        let (english, _) = try make(.unavailable, language: .english)
        english.next()
        try write(english, "4-setup-en-dark", appearance: .darkAqua)
    }
}
