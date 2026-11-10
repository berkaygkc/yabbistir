import Foundation
import Testing
@testable import YabLocalization

@Suite struct L10nTests {
    @Test func turkishString() {
        #expect(L10n.string("panel.footer.paste", .turkish) == "Yapıştır")
    }

    @Test func englishString() {
        #expect(L10n.string("panel.footer.paste", .english) == "Paste")
    }

    @Test func formatArgument() {
        #expect(L10n.string("panel.empty.noResults", .turkish, "uuid") == "“uuid” için sonuç yok")
        #expect(L10n.string("panel.empty.noResults", .english, "uuid") == "No results for “uuid”")
    }

    /// The ⇧ panel's count is a plural, so one transform never reads "1 transforms". Turkish keeps the noun singular
    /// after a number.
    @Test(arguments: [
        (1, "1 transform", "1 dönüşüm"),
        (2, "2 transforms", "2 dönüşüm"),
        (0, "0 transforms", "0 dönüşüm"),
    ])
    func transformCountIsAPlural(count: Int, english: String, turkish: String) {
        #expect(L10n.string("transforms.count", .english, count) == english)
        #expect(L10n.string("transforms.count", .turkish, count) == turkish)
    }

    /// Every key the app's sources use exists in both languages (a missing key would show as its name).
    @Test func everyKeyUsedInSourcesIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = [root.appendingPathComponent("Sources"), root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")]
        let pattern = /"((?:panel|menu|notice|kind|actions|pin|editor|preview|category|stack|extensions|transforms|settings|permissions|jobs|ai(?=\.(?:unavailable|failed))|history(?=\.denied)|host(?=\.tooSlow)|translate|import|onboarding|time)\.[A-Za-z.]+)"/
        var keys = Set<String>()
        for folder in folders {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files where file.pathExtension == "swift" {
                for match in try String(contentsOf: file, encoding: .utf8).matches(of: pattern) { keys.insert(String(match.1)) }
            }
        }
        #expect(keys.count > 20)
        let missing = keys.filter { L10n.string($0, .english) == $0 || L10n.string($0, .turkish) == $0 }.sorted()
        #expect(missing.isEmpty, "\(missing)")
    }

    @Test func unknownKeyReturnsKey() {
        #expect(L10n.string("does.not.exist", .turkish) == "does.not.exist")
    }

    /// The source catalog's text for `key` in `code`.
    static func catalogValue(_ key: String, _ code: String) throws -> String {
        let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = kit.appendingPathComponent("Sources/YabLocalization/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = catalog?["strings"] as? [String: Any]
        let localizations = (strings?[key] as? [String: Any])?["localizations"] as? [String: Any]
        let unit = (localizations?[code] as? [String: Any])?["stringUnit"] as? [String: Any]
        return try #require(unit?["value"] as? String, "\(key) has no \(code)")
    }

    /// The built bundle answers each language from its own lproj: a key reads as the catalog's text in that language,
    /// never English's, and the two Chineses never answer for each other (a missing `ko.lproj` or a `zh-Hant` that
    /// resolved to `zh-Hans` would pass every test that reads the catalog's JSON).
    @Test(arguments: AppLanguage.allCases.filter { $0 != .english })
    func eachLanguageResolvesToItsOwnStrings(_ language: AppLanguage) throws {
        let chinese: [AppLanguage: AppLanguage] = [.simplifiedChinese: .traditionalChinese, .traditionalChinese: .simplifiedChinese]
        for key in ["panel.footer.paste", "panel.footer.transform", "panel.search.placeholder", "time.minutes"] {
            let text = L10n.string(key, language), expected = try Self.catalogValue(key, language.rawValue)
            #expect(text == expected, "\(language.rawValue) \(key)")
            #expect(text != L10n.string(key, .english), "\(language.rawValue) \(key) reads English")
            if let other = chinese[language] {
                #expect(text != L10n.string(key, other), "\(language.rawValue) \(key) reads \(other.rawValue)")
            }
        }
    }
}

@Suite struct FormattingTests {
    let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

    @Test(arguments: [
        (30.0, "now", "şimdi"),
        (4 * 60.0, "4m", "4 dk"),
        (2 * 3600.0, "2h", "2 sa"),
        (30 * 3600.0, "yesterday", "dün"),
        (6 * 86_400.0, "6d", "6 gün"),
    ])
    func shortRelativeTime(seconds: Double, english: String, turkish: String) {
        let date = now.addingTimeInterval(-seconds)
        #expect(ShortRelativeTime.string(from: date, now: now, language: .english) == english)
        #expect(ShortRelativeTime.string(from: date, now: now, language: .turkish) == turkish)
    }

    /// The labels are read from the catalog once and joined to their count: they read as formatting the catalog's own
    /// string would, in every language, with the count as `\(days)` always wrote it (no grouping separator).
    @Test func countLabelsReadAsTheCatalogsFormat() {
        let cases: [(key: String, seconds: Double, count: Int)] = [
            ("time.minutes", 7 * 60, 7), ("time.hours", 5 * 3600, 5), ("time.days", 12 * 86_400, 12), ("time.days", 1234 * 86_400, 1234),
        ]
        for language in AppLanguage.allCases {
            for c in cases {
                let catalog = L10n.string(c.key, language).replacingOccurrences(of: "%lld", with: String(c.count))
                let label = ShortRelativeTime.string(from: now.addingTimeInterval(-c.seconds), now: now, language: language)
                #expect(label == catalog, "\(language) \(c.key)")
            }
        }
    }

    /// A long-kept item's days read as they did before the catalog: "1234d", never "1,234d" or "1.234 gün".
    @Test(arguments: [
        (999, "999d", "999 gün"),
        (1000, "1000d", "1000 gün"),
        (1234, "1234d", "1234 gün"),
    ])
    func dayCountsAreNeverGrouped(days: Int, english: String, turkish: String) {
        let date = now.addingTimeInterval(-Double(days) * 86_400)
        #expect(ShortRelativeTime.string(from: date, now: now, language: .english) == english)
        #expect(ShortRelativeTime.string(from: date, now: now, language: .turkish) == turkish)
    }

    /// Each language's words, written out here rather than read from the catalog; `#` is the count.
    static let relativeWords: [AppLanguage: (now: String, minutes: String, hours: String, yesterday: String, days: String)] = [
        .english: ("now", "#m", "#h", "yesterday", "#d"),
        .german: ("jetzt", "# Min.", "# Std.", "gestern", "# Tg."),
        .spanish: ("ahora", "# min", "# h", "ayer", "# d"),
        .french: ("à l\u{2019}instant", "#\u{A0}min", "#\u{A0}h", "hier", "#\u{A0}j"),
        .turkish: ("şimdi", "# dk", "# sa", "dün", "# gün"),
        .japanese: ("今", "#分", "#時間", "昨日", "#日"),
        .korean: ("지금", "#분", "#시간", "어제", "#일"),
        .simplifiedChinese: ("刚刚", "#分钟前", "#小时前", "昨天", "#天前"),
        .traditionalChinese: ("剛剛", "#分鐘前", "#小時前", "昨天", "#天前"),
    ]

    /// Every language's labels on both sides of each step: under a minute is now; then minutes; hours (rounded) up to a
    /// day; yesterday up to two days; then days.
    @Test(arguments: AppLanguage.allCases)
    func relativeTimeBoundaries(_ language: AppLanguage) throws {
        let words = try #require(Self.relativeWords[language])
        func count(_ template: String, _ n: Int) -> String { template.replacingOccurrences(of: "#", with: String(n)) }
        let rows: [(seconds: Double, label: String)] = [
            (0, words.now), (59, words.now),
            (60, count(words.minutes, 1)), (3599, count(words.minutes, 59)),
            (3600, count(words.hours, 1)), (86_399, count(words.hours, 24)),
            (86_400, words.yesterday), (172_799, words.yesterday),
            (172_800, count(words.days, 2)),
        ]
        for row in rows {
            let label = ShortRelativeTime.string(from: now.addingTimeInterval(-row.seconds), now: now, language: language)
            #expect(label == row.label, "\(language.rawValue) at \(Int(row.seconds)) s")
        }
    }

    /// Language names are written in the app's language, whatever the system's.
    @Test func languagePairsAreNamedInTheAppsLanguage() {
        #expect(LanguageNames.pair(from: "en", to: "tr", in: .turkish) == "İngilizce → Türkçe")
        #expect(LanguageNames.pair(from: "en", to: "tr", in: .english) == "English → Turkish")
        #expect(LanguageNames.name("ja", in: .turkish) == "Japonca")
        // A code no locale knows is shown as it is.
        #expect(LanguageNames.name("xx", in: .english) == "xx")
    }

    @Test func countFormatting() {
        #expect(NumberFormatting.count(1355, language: .turkish) == "1.355")
        #expect(NumberFormatting.count(1355, language: .english) == "1,355")
    }
}

@MainActor @Suite struct LanguageStoreTests {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "yabbistir-tests-\(UUID().uuidString)")!
    }

    @Test func defaultLanguageIsEnglish() {
        #expect(LanguageStore(defaults: freshDefaults(), preferredLanguages: []).language == .english)
    }

    @Test func languagePersists() {
        let defaults = freshDefaults()
        LanguageStore(defaults: defaults, preferredLanguages: ["en"]).language = .turkish
        #expect(LanguageStore(defaults: defaults, preferredLanguages: ["en"]).language == .turkish)
    }
}
