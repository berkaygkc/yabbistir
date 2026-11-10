import AppKit
import SwiftUI
import Testing
import YabLocalization
@testable import YabUI

/// The first-run language picker: one menu button, the whole tile, reading the current language in its own name. Its
/// menu lists the nine names with a check on the current one; choosing one there sets (and keeps) the app's language.
@MainActor @Suite struct LanguagePickerTests {
    func store(_ defaults: UserDefaults = UserDefaults(suiteName: "yab-picker-\(UUID().uuidString)")!) -> LanguageStore {
        LanguageStore(defaults: defaults, preferredLanguages: ["en"])
    }

    /// The picker alone, its window exactly the tile.
    func host(_ store: LanguageStore) -> (NSWindow, NSView) {
        let size = NSHostingView(rootView: LanguagePicker(store: store)).fittingSize
        return AccessibilityTree.host(LanguagePicker(store: store), size: size)
    }

    /// The picker's one control. The chevron is decoration: shown to VoiceOver, it was a second menu button.
    func menuButton(in host: NSView) throws -> AccessibilityTree.Element {
        let buttons = AccessibilityTree.elements(under: host).filter { $0.role == NSAccessibility.Role.menuButton.rawValue }
        #expect(buttons.count == 1)
        return try #require(buttons.first)
    }

    @Test func thePickerReadsTheCurrentLanguage() throws {
        let store = store()
        let (window, host) = host(store)
        let button = try menuButton(in: host)
        #expect(button.label == "Language")
        #expect(button.value == "English")

        store.language = .traditionalChinese
        AccessibilityTree.settle(host)
        let changed = try menuButton(in: host)
        #expect(changed.label == L10n.string("settings.general.language", .traditionalChinese))
        #expect(changed.value == "繁體中文")
        _ = window
    }

    /// The tile is the menu's own label, so all of it is the control: the button is the tile, 26 pt tall, and not just
    /// its words (the system pop-up it replaced left 5 to 8 pt of the tile dead around it).
    @Test func theWholeTileIsTheControl() throws {
        let (window, host) = host(store())
        let tile = window.convertToScreen(host.convert(host.bounds, to: nil))
        let frame = try #require(try menuButton(in: host).frame)
        #expect(tile.height == 26)
        #expect(abs(frame.minX - tile.minX) <= 0.5 && abs(frame.maxX - tile.maxX) <= 0.5, "\(frame) in \(tile)")
        #expect(abs(frame.minY - tile.minY) <= 0.5 && abs(frame.maxY - tile.maxY) <= 0.5, "\(frame) in \(tile)")
    }

    /// Opened as VoiceOver opens it, the picker's menu lists the nine names, English checked. Choosing "Deutsch" there
    /// turns the app to German, keeps it, and the tile reads it.
    @Test func choosingDeutschInTheMenuSetsIt() throws {
        let defaults = UserDefaults(suiteName: "yab-picker-\(UUID().uuidString)")!
        let store = store(defaults)
        let (window, host) = host(store)

        final class Seen { var titles: [String] = []; var checked: [String] = [] }
        let seen = Seen()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                                              queue: nil) { note in
            guard let menu = note.object as? NSMenu, menu.indexOfItem(withTitle: "Deutsch") >= 0 else { return }
            seen.titles = menu.items.map(\.title)
            seen.checked = menu.items.filter { $0.state == .on }.map(\.title)
            // Chosen from inside the menu's own tracking, as a click would.
            RunLoop.main.perform(inModes: [.eventTracking, .default]) {
                menu.performActionForItem(at: menu.indexOfItem(withTitle: "Deutsch"))
                menu.cancelTracking()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(try menuButton(in: host).showMenu())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(seen.titles == AppLanguage.allCases.map(\.nativeName))
        #expect(seen.checked == ["English"])
        #expect(store.language == .german)
        #expect(defaults.string(forKey: LanguageStore.defaultsKey) == "de")
        AccessibilityTree.settle(host)
        #expect(try menuButton(in: host).value == "Deutsch")
        _ = window
    }
}
