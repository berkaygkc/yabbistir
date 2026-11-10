import Foundation
import Testing
@testable import YabLocalization

@Suite struct AppLanguageTests {
    /// The order every language list shows: menus, Settings and the site.
    @Test func languagesComeInTheMenuOrder() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["en", "de", "es", "fr", "tr", "ja", "ko", "zh-Hans", "zh-Hant"])
    }

    @Test func eachLanguageHasItsLocaleAndItsOwnName() {
        // Foundation shortens zh_Hans_CN to zh_CN, keeping the script.
        #expect(AppLanguage.allCases.map(\.locale) == ["en_US", "de_DE", "es_ES", "fr_FR", "tr_TR", "ja_JP", "ko_KR", "zh_Hans_CN", "zh_Hant_TW"]
            .map(Locale.init(identifier:)))
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
        (["pt-BR", "ja-JP"], .japanese),
        (["pt-BR"], .english),
        ([], .english),
        (["en-GB", "de-DE"], .english),
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
        UserDefaults(suiteName: "yab-lang-first-\(UUID().uuidString)")!
    }

    /// A fresh install speaks the system's language from its first window, and stores it.
    @Test func aFreshInstallFollowsTheSystem() {
        let defaults = freshDefaults()
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["ja-JP"]).language == .japanese)
        #expect(defaults.string(forKey: "appLanguage") == "ja")
    }

    /// Someone who finished onboarding before the language followed the system, and never picked one, stays in
    /// English after the update.
    @Test func anOnboardedPersonWithoutAChoiceStaysInEnglish() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "pref.onboarded")
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["de-DE"]).language == .english)
        #expect(defaults.string(forKey: "appLanguage") == "en")
    }

    @Test func aStoredChoiceWinsWhateverTheSystemSays() {
        let defaults = freshDefaults()
        defaults.set("fr", forKey: "appLanguage")
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["ja-JP"]).language == .french)
        #expect(LanguageStore(defaults: defaults, preferredLanguages: []).language == .french)
        defaults.set(true, forKey: "pref.onboarded")
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["de-DE"]).language == .french)
        #expect(defaults.string(forKey: "appLanguage") == "fr")
    }

    @Test func anUnknownStoredValueFallsBackToTheSameRules() {
        let fresh = freshDefaults()
        fresh.set("xx", forKey: "appLanguage")
        #expect(LanguageStore(defaults: fresh, preferredLanguages: ["ja-JP"]).language == .japanese)
        #expect(fresh.string(forKey: "appLanguage") == "ja")

        let onboarded = freshDefaults()
        onboarded.set("xx", forKey: "appLanguage")
        onboarded.set(true, forKey: "pref.onboarded")
        #expect(LanguageStore(defaults: onboarded, preferredLanguages: ["ja-JP"]).language == .english)
        #expect(onboarded.string(forKey: "appLanguage") == "en")
    }

    /// The system decides once: changing the Mac's language later does not move the app's.
    @Test func theFirstLaunchDecidesOnce() {
        let defaults = freshDefaults()
        _ = LanguageStore(defaults: defaults, preferredLanguages: ["ko-KR"])
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["de-DE"]).language == .korean)
    }
}
