import Foundation
import Testing
import YabTestSupport
@testable import YabLocalization

@Suite struct AppLanguageTests {
    /// The order every language list shows: menus, Settings and the site.
    @Test func languagesComeInTheMenuOrder() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["en", "de", "es", "fr", "tr", "ja", "ko", "zh-Hans", "zh-Hant"])
    }

    @Test func eachLanguageHasItsOwnName() {
        #expect(AppLanguage.simplifiedChinese.locale.language.script == .hanSimplified)
        #expect(AppLanguage.traditionalChinese.locale.language.script == .hanTraditional)
        #expect(AppLanguage.allCases.map(\.nativeName)
            == ["English", "Deutsch", "Español", "Français", "Türkçe", "日本語", "한국어", "简体中文", "繁體中文"])
    }

    /// Every language the catalogs ship can be picked, and only those.
    @Test func theCasesAreTheShippedLanguages() {
        #expect(Set(AppLanguage.allCases.map(\.rawValue)) == Set(CatalogTests.shippedLanguages))
    }

    static let systemLanguages: [([String], AppLanguage)] = [
        (["de-AT"], .german),
        (["es-419"], .spanish),
        (["fr-CA"], .french),
        (["zh-Hant-TW"], .traditionalChinese),
        (["zh-HK"], .traditionalChinese),
        (["zh-MO"], .traditionalChinese),
        (["zh-TW"], .traditionalChinese),
        (["zh-Hans-CN"], .simplifiedChinese),
        (["zh-CN"], .simplifiedChinese),
        (["zh-SG"], .simplifiedChinese),
        (["zh"], .simplifiedChinese),
        // An explicit script wins over the region.
        (["zh-Hans-HK"], .simplifiedChinese),
        (["zh-Hans-TW"], .simplifiedChinese),
        (["zh-Hant-CN"], .traditionalChinese),
        (["zh-Hant-HK"], .traditionalChinese),
        (["zh-Hant"], .traditionalChinese),
        // Underscores and any letter case.
        (["zh_Hant_TW"], .traditionalChinese),
        (["ZH-hk"], .traditionalChinese),
        // Cantonese reads Chinese: Traditional unless it names Simplified.
        (["yue-Hant-HK"], .traditionalChinese),
        (["yue"], .traditionalChinese),
        (["yue-Hans-CN"], .simplifiedChinese),
        (["pt-BR", "ja-JP"], .japanese),
        (["pt-BR"], .english),
        ([], .english),
        (["en-GB", "de-DE"], .english),
        (["en-TR"], .english),
        (["tr-TR"], .turkish),
        (["ko-KR"], .korean),
    ]

    /// The first of the system's languages the app speaks; English when it speaks none of them.
    @Test(arguments: systemLanguages)
    func preferredLanguage(identifiers: [String], expected: AppLanguage) {
        #expect(AppLanguage.preferred(from: identifiers) == expected)
    }
}

@MainActor @Suite struct LanguageStoreFirstLaunchTests {
    func freshDefaults() -> UserDefaults {
        TestScratch.defaults("yab-lang-first")
    }

    /// A fresh install speaks the system's language from its first window, and stores it.
    @Test func aFreshInstallFollowsTheSystem() {
        let defaults = freshDefaults()
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["ja-JP"]).language == .japanese)
        #expect(defaults.string(forKey: "appLanguage") == "ja")
    }

    /// Someone who used the app before the language followed the system, and never picked one, stays in English
    /// after the update.
    @Test func anExistingUserWithoutAChoiceStaysInEnglish() {
        let defaults = freshDefaults()
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["de-DE"], isExistingUser: true).language == .english)
        #expect(defaults.string(forKey: "appLanguage") == "en")
    }

    @Test func aStoredChoiceWinsWhateverTheSystemSays() {
        let defaults = freshDefaults()
        defaults.set("fr", forKey: "appLanguage")
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["ja-JP"]).language == .french)
        #expect(LanguageStore(defaults: defaults, preferredLanguages: []).language == .french)
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["de-DE"], isExistingUser: true).language == .french)
        #expect(defaults.string(forKey: "appLanguage") == "fr")
    }

    @Test func anUnknownStoredValueFallsBackToTheSameRules() {
        let fresh = freshDefaults()
        fresh.set("xx", forKey: "appLanguage")
        #expect(LanguageStore(defaults: fresh, preferredLanguages: ["ja-JP"]).language == .japanese)
        #expect(fresh.string(forKey: "appLanguage") == "ja")

        let existing = freshDefaults()
        existing.set("xx", forKey: "appLanguage")
        #expect(LanguageStore(defaults: existing, preferredLanguages: ["ja-JP"], isExistingUser: true).language == .english)
        #expect(existing.string(forKey: "appLanguage") == "en")
    }

    /// The system decides once: changing the Mac's language later does not move the app's.
    @Test func theFirstLaunchDecidesOnce() {
        let defaults = freshDefaults()
        _ = LanguageStore(defaults: defaults, preferredLanguages: ["ko-KR"])
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["de-DE"]).language == .korean)
    }

    /// The strings AppKit draws (open panels, alert buttons, text menus, the shortcut recorder) speak the app's
    /// language, not the Mac's: each decision and change is written as the app's own "AppleLanguages", which AppKit
    /// reads at launch.
    @Test func systemStringsFollowTheChoice() {
        let defaults = freshDefaults()
        let store = LanguageStore(defaults: defaults, preferredLanguages: ["ja-JP"])
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ja"])
        store.language = .german
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["de"])
    }

    /// An updating user's language, kept English or picked before, is written too.
    @Test func aKeptLanguageIsTheSystemStringsToo() {
        let existing = freshDefaults()
        _ = LanguageStore(defaults: existing, preferredLanguages: ["de-DE"], isExistingUser: true)
        #expect(existing.stringArray(forKey: "AppleLanguages") == ["en"])

        let stored = freshDefaults()
        stored.set("tr", forKey: "appLanguage")
        _ = LanguageStore(defaults: stored, preferredLanguages: ["ja-JP"])
        #expect(stored.stringArray(forKey: "AppleLanguages") == ["tr"])
    }

    /// The first launch decides by the system's languages it is handed, never by an "AppleLanguages" in the app's own
    /// defaults: that is the app's override, not the Mac's.
    @Test func theFirstLaunchNeverReadsTheOverride() {
        let defaults = freshDefaults()
        defaults.set(["ko"], forKey: "AppleLanguages")
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["de-DE"]).language == .german)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["de"])
    }
}
