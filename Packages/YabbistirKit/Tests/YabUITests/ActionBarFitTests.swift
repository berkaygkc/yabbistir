import AppKit
import Foundation
import SwiftUI
import Testing
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization
@testable import YabUI

/// The footer laid out at one column's width, in every language: it never runs past the column. English and Turkish keep
/// every word; where the words don't all fit (German, Spanish), Transform and then Actions go by their keys alone.
@MainActor @Suite struct ActionBarFitTests {
    let store: ItemStore
    let item: Int64
    let fake = FakeCommands()

    init() throws {
        store = try ItemStore.temporary()
        let clip = CapturedClip(items: [[PasteboardRepresentation(type: TypeIdentifiers.plainText, data: Data("SGVsbG8=".utf8))]],
                                source: nil, device: .local, capturedAt: Date())
        item = try #require(try store.ingest(clip)).item.id!
        fake.transformsByItem[item] = [FakeCommands.command("dev.example.base64/decode", title: "Base64", keywords: ["b64"])]
    }

    /// The item selected, with a transform, so the bar shows all three buttons.
    func bar(_ language: AppLanguage, inputMethod: Bool = false) throws -> ActionBarView {
        let languages = LanguageStore(defaults: UserDefaults(suiteName: "yab-fit-\(UUID().uuidString)")!, preferredLanguages: ["en"])
        languages.language = language
        let model = PanelViewModel(library: try Library(store: store), language: languages, extensions: fake, now: { Date() })
        model.reset()
        model.select(item, in: .history)
        model.inputMethodActive = inputMethod
        try #require(model.selectedTransformCount > 0)
        return ActionBarView(model: model, onPaste: { _ in }, onAction: { _ in })
    }

    /// How wide `view` lays itself out when offered `width`.
    func width(_ view: some View, offered width: CGFloat) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: Tokens.Metrics.footerHeight)).width
    }

    /// How wide `view` is with all its words on one line.
    func idealWidth(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    let column = Tokens.Metrics.columnWidth
    var room: CGFloat { ActionBarView.room(in: column) }

    @Test(arguments: AppLanguage.allCases)
    func theBarFitsOneColumn(_ language: AppLanguage) throws {
        for inputMethod in [false, true] {
            let width = width(try bar(language, inputMethod: inputMethod), offered: column)
            #expect(width <= column, "\(language.rawValue)\(inputMethod ? " ⌘T" : ""): \(width) pt")
        }
    }

    /// Drawn at one column's width, the buttons are the first set whose words fit, against the trailing inset: their
    /// words start where that set's Paste starts and end before the inset. A set measured for the room but placed in a
    /// narrower one would start where the wider set starts and stop short of the inset.
    @Test(arguments: AppLanguage.allCases)
    func theBarShowsTheFirstSetThatFits(_ language: AppLanguage) throws {
        for inputMethod in [false, true] {
            let bar = try bar(language, inputMethod: inputMethod)
            let words = try #require(ActionBarView.Words.allCases.first { idealWidth(bar.itemActions($0)) <= room })
            let start = column - ActionBarView.trailingInset - idealWidth(bar.itemActions(words))
            let ink = try ink(bar)
            let name = "\(language.rawValue)\(inputMethod ? " ⌘T" : "") \(words)"
            // Paste's word starts 10 pt into its button; ⌘K's legend ends inside its keycap, 6 pt inside the button.
            #expect(abs(ink.lowerBound - (start + 10)) <= 2, "\(name): words start at \(ink.lowerBound), expected \(start + 10)")
            #expect(ink.upperBound <= column - ActionBarView.trailingInset - 6, "\(name): ink ends at \(ink.upperBound)")
            #expect(ink.upperBound >= column - ActionBarView.trailingInset - 20, "\(name): ink ends at \(ink.upperBound)")
        }
    }

    /// Where the bar's words and legends are, left to right, drawn dark over black at one column's width: the lit
    /// columns of pixels (the tints, keycaps and hairlines stay dim).
    func ink(_ bar: ActionBarView) throws -> ClosedRange<CGFloat> {
        let host = NSHostingView(rootView: bar.frame(width: column).background(Color.black).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: column, height: Tokens.Metrics.footerHeight)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / column
        let lit = (0..<bitmap.pixelsWide).filter { x in
            (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.3 }
        }
        let first = try #require(lit.first), last = try #require(lit.last)
        return CGFloat(first) / scale...CGFloat(last + 1) / scale
    }

    /// Only Transform ever has to give its word up: "Einsetzen ↵ | Umwandeln ⇧ | Aktionen ⌘K" ran about 26 pt past the
    /// column, "Einsetzen ↵ | ⇧ | Aktionen ⌘K" fits. Actions' keys alone are the last resort.
    @Test(arguments: AppLanguage.allCases)
    func actionsKeepsItsWord(_ language: AppLanguage) throws {
        for inputMethod in [false, true] {
            let width = idealWidth(try bar(language, inputMethod: inputMethod).itemActions(.firstAndActions))
            #expect(width <= room, "\(language.rawValue)\(inputMethod ? " ⌘T" : ""): \(width) pt in \(room) pt")
        }
    }

    /// English and Turkish read as they always have: every button keeps its words.
    @Test(arguments: [AppLanguage.english, .turkish])
    func englishAndTurkishKeepEveryWord(_ language: AppLanguage) throws {
        let all = idealWidth(try bar(language).itemActions(.all))
        #expect(all <= room, "\(language.rawValue): \(all) pt in \(room) pt")
    }

    /// German's Transform goes by its key alone in one column ("Einsetzen ↵ | ⇧ | Aktionen ⌘K"), and VoiceOver still
    /// reads it as "Umwandeln", not "⇧"; the pointer's tooltip says the same.
    @Test func aKeysOnlyButtonKeepsItsName() throws {
        let bar = try bar(.german)
        #expect(ActionBarView.Words.allCases.first { idealWidth(bar.itemActions($0)) <= room } == .firstAndActions)
        let (window, host) = AccessibilityTree.host(bar.frame(width: column),
                                                    size: NSSize(width: column, height: Tokens.Metrics.footerHeight))
        let buttons = AccessibilityTree.elements(under: host).filter { $0.role == NSAccessibility.Role.button.rawValue }
        #expect(buttons.map(\.label) == ["Einsetzen, ↵", "Umwandeln", "Aktionen, ⌘, K"])
        let transform = try #require(buttons.first { $0.label == "Umwandeln" })
        #expect(transform.help == "Umwandeln")
        _ = window
    }

    /// Under an input method Transform's keys read ⌘T, with or without its word.
    @Test func theInputMethodKeysStay() throws {
        let keys = idealWidth(try bar(.german, inputMethod: true).itemActions(.firstOnly))
        let plain = idealWidth(try bar(.german).itemActions(.firstOnly))
        // ⌘T is two keycaps where ⇧ is one.
        #expect(keys - plain >= 20)
    }

    /// What Transform's keycaps say, drawn with its word in every language: ⇧ on a plain layout, ⌘ and T under an input
    /// method.
    @Test(arguments: AppLanguage.allCases)
    func theTransformKeycapsReadTheKeyThatWorks(_ language: AppLanguage) throws {
        let transform = L10n.string("panel.footer.transform", language)
        for (inputMethod, keys) in [(false, "⇧"), (true, "⌘, T")] {
            let (window, host) = AccessibilityTree.host(try bar(language, inputMethod: inputMethod).itemActions(.all).fixedSize(),
                                                        size: NSSize(width: 600, height: Tokens.Metrics.footerHeight))
            let buttons = AccessibilityTree.elements(under: host).filter { $0.role == NSAccessibility.Role.button.rawValue }
            #expect(buttons.map(\.label).contains("\(transform), \(keys)"), "\(language.rawValue): \(buttons.map(\.label))")
            _ = window
        }
    }
}
