import AppKit
import SwiftUI
import Testing
import YabCore
import YabLocalization
@testable import YabUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Puts a real panel on screen and takes keyboard focus for a few seconds, so it only runs on request:
/// `TEST_RUNNER_YAB_ONSCREEN=1 make test ONLY=YabUITests/PanelPresentationTests`.
@MainActor @Suite struct PanelPresentationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_ONSCREEN"] != nil))
    func entranceReachesFullOpacityOnEveryShow() throws {
        let store = try ItemStore.temporary()
        let base = Date()
        for i in 0..<10 {
            _ = try store.ingest(CapturedClip(
                items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("satır \(i)".utf8))]],
                source: nil, device: .local, capturedAt: base.addingTimeInterval(Double(-i * 60))))
        }
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-onscreen-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        let library = try Library(store: store)
        let links = try library.createCategory(name: "Bağlantılar")
        try library.toggle(try #require(library.index.search("", limit: 1).ids.first), inCategory: links.id!)
        let model = PanelViewModel(library: library, language: language)
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                 backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: PanelView(model: model, material: .liquidGlass))
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let frame = CGRect(x: visible.minX + 20, y: visible.minY + 20, width: 340, height: 476)

        func spin(_ milliseconds: Int) { RunLoop.main.run(until: Date().addingTimeInterval(Double(milliseconds) / 1000)) }
        func contentOpacity() -> Float {
            let layer = panel.contentView?.layer?.sublayers?.first { $0.bounds.width >= 200 }
            return layer.map { $0.presentation()?.opacity ?? $0.opacity } ?? -1
        }
        // Reopening right away and after a search used to leave the panel transparent until the next keystroke.
        var opacities: [String: Float] = [:]
        for step in ["first show", "reopen", "reopen after search", "reopen again", "reopen with a category column"] {
            if step == "reopen after search" { _ = model.handle(.type("7")) }
            if step == "reopen with a category column" { model.toggleShown(links.id!) }
            PanelPresentation.show(panel, frame: frame, model: model)
            spin(300)
            opacities[step] = contentOpacity()
            panel.orderOut(nil)
            spin(100)
        }
        #expect(opacities.values.allSatisfy { $0 > 0.95 }, "\(opacities)")
    }

    /// The window is exactly as wide as the visible columns: it grows and shrinks with them and
    /// never runs off screen when they do not all fit.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_ONSCREEN"] != nil))
    func windowWidthFollowsTheColumns() throws {
        let store = try ItemStore.temporary()
        let library = try Library(store: store)
        for minute in 0..<5 {
            let item = try #require(try store.ingest(CapturedClip(
                items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("satır \(minute)".utf8))]],
                source: nil, device: .local, capturedAt: Date().addingTimeInterval(Double(-minute * 60))))).item
            library.didIngest(item)
        }
        var categories: [ClipCategory] = []
        for name in ["A", "B", "C", "D", "E", "F"] { categories.append(try library.createCategory(name: name)) }
        let language = LanguageStore(defaults: UserDefaults(suiteName: "yab-width-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        let model = PanelViewModel(library: library, language: language)
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                 backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = PanelPresentation.host(PanelView(model: model, material: .liquidGlass))
        let visible = NSScreen.main?.visibleFrame ?? .zero
        model.availableWidth = 1440 - 24
        func spin(_ milliseconds: Int) { RunLoop.main.run(until: Date().addingTimeInterval(Double(milliseconds) / 1000)) }
        // As in the app: SwiftUI redraws first, the width sync runs on a later turn.
        // The window changes width only through fitWidth (the hosting view must not size it).
        func fit(_ step: String) {
            let width = panel.frame.width
            spin(100)
            #expect(panel.frame.width == width, "\(step): resized before the sync")
            PanelPresentation.fitWidth(panel, model: model, visibleFrame: visible)
            spin(700)
        }

        model.refresh()
        PanelPresentation.show(panel, frame: CGRect(x: visible.minX + 20, y: visible.minY + 20, width: model.sheetWidth, height: 476), model: model)
        spin(300)
        #expect(panel.frame.width == model.sheetWidth, "single column")

        model.toggleShown(categories[0].id!)
        fit("open")
        #expect(panel.frame.width == model.sheetWidth, "after opening a column")

        model.toggleShown(categories[0].id!)
        fit("close")
        #expect(panel.frame.width == model.sheetWidth, "after closing it")

        for category in categories { model.toggleShown(category.id!) }
        fit("overflow")
        #expect(model.visibleColumnCount < model.columns.count)
        #expect(panel.frame.width == model.sheetWidth, "overflow")
        #expect(panel.frame.maxX <= visible.maxX)
        panel.orderOut(nil)
    }
}
