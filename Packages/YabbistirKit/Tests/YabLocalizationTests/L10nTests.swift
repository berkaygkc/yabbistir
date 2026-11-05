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
        let pattern = /"((?:panel|menu|notice|kind|actions|pin|editor|preview|category|stack|extensions|transforms|settings|permissions|jobs|ai(?=\.(?:unavailable|failed))|history(?=\.denied)|host(?=\.tooSlow)|translate|import|onboarding)\.[A-Za-z.]+)"/
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
        #expect(LanguageStore(defaults: freshDefaults()).language == .english)
    }

    @Test func languagePersists() {
        let defaults = freshDefaults()
        LanguageStore(defaults: defaults).language = .turkish
        #expect(LanguageStore(defaults: defaults).language == .turkish)
    }
}
