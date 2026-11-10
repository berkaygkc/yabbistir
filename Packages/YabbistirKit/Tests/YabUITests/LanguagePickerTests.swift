import AppKit
import SwiftUI
import Testing
import YabLocalization
@testable import YabUI

/// The first-run language pop-up: the system's own pop-up button, reading the current language in its own name; choosing
/// one sets (and keeps) the app's language.
@MainActor @Suite struct LanguagePickerTests {
    func store(_ defaults: UserDefaults = UserDefaults(suiteName: "yab-picker-\(UUID().uuidString)")!) -> LanguageStore {
        LanguageStore(defaults: defaults, preferredLanguages: ["en"])
    }

    @Test func thePopUpReadsTheCurrentLanguage() throws {
        let store = store()
        let host = NSHostingView(rootView: LanguagePicker(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let popUp = try #require(Self.popUp(in: host))
        #expect(popUp.title == "English")

        store.language = .traditionalChinese
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(popUp.title == "繁體中文")
    }

    /// The selection the pop-up writes when an item is chosen.
    @Test func choosingALanguageSetsIt() {
        let defaults = UserDefaults(suiteName: "yab-picker-\(UUID().uuidString)")!
        let store = store(defaults)
        let picker = LanguagePicker(store: store)
        picker.$store.language.wrappedValue = .german
        #expect(store.language == .german)
        #expect(defaults.string(forKey: LanguageStore.defaultsKey) == "de")
    }

    private static func popUp(in view: NSView) -> NSPopUpButton? {
        if let popUp = view as? NSPopUpButton { return popUp }
        return view.subviews.lazy.compactMap(popUp(in:)).first
    }
}
