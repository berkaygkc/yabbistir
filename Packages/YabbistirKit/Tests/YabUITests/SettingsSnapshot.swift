import AppKit
import SwiftUI
import Testing
import YabCore
import YabLocalization
@testable import YabUI

/// Renders Settings panes to PNG for visual review. Off by default; run with
/// `TEST_RUNNER_YAB_SNAPSHOT_DIR=/some/dir make test ONLY=YabUITests/SettingsSnapshot`.
@MainActor @Suite struct SettingsSnapshot {
    static let dir = ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"]
    static let turkish: LanguageStore = {
        let store = LanguageStore(defaults: UserDefaults(suiteName: "snap-settings-\(UUID())")!, preferredLanguages: ["en"])
        store.language = .turkish
        return store
    }()

    /// Drawn through AppKit at 2× in a real (offscreen) window, so List and Form render as they do in Settings.
    private func write(_ view: some View, size: NSSize, _ name: String) throws {
        let dir = URL(fileURLWithPath: try #require(Self.dir), isDirectory: true).appendingPathComponent("settings-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderCategories() throws {
        let store = try ItemStore.temporary()
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: "public.utf8-plain-text", data: Data("SELECT 1".utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        let itemID = try #require(try store.ingest(clip)).item.id!
        let code = try store.createCategory(name: "Kod parçaları", color: .slate, visibility: .always)
        try store.add(itemID: itemID, toCategory: code.id!)
        let library = try Library(store: store)
        try library.syncSourceCategories([SourceCategorySeed(key: "dev.example.kasa/vault", name: "Kasa")])
        for (name, count) in [("categories-2", 2), ("categories-1", 1), ("categories-0", 0), ("categories-10", 10)] {
            let rowStore = try ItemStore.temporary()
            let rowLibrary = try Library(store: rowStore)
            if count >= 1 {
                try rowLibrary.syncSourceCategories([SourceCategorySeed(key: "dev.example.kasa/vault", name: "Kasa")])
            }
            if count >= 2 { _ = try rowStore.createCategory(name: "Kod parçaları", color: .slate, visibility: .always) }
            if count > 2 { for n in 3...count { _ = try rowStore.createCategory(name: "Kategori \(n)", color: .sage) } }
            let editor = CategoryEditorModel(library: rowLibrary, language: Self.turkish)
            try write(CategoriesSettingsView(model: editor, presence: SettingsPresence()), size: NSSize(width: 640, height: 520), name)
        }
        _ = library
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_SNAPSHOT_DIR"] != nil))
    func renderAbout() throws {
        let model = AboutModel(version: "0.5.0", build: "42", language: Self.turkish, checkForUpdates: {}, readNotice: { _ in nil },
                               openURL: { _ in })
        try write(AboutSettingsView(model: model), size: NSSize(width: 640, height: 520), "about")
    }
}
