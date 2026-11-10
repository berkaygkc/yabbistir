import Foundation

/// Compact "time since copied" labels for list rows: now · 4m · 2h · yesterday · 6d.
public enum ShortRelativeTime {
    /// A language's labels, read from the catalog once: every row of every column labels its time on each keystroke,
    /// and a lookup and a format per row cost a third of a frame at 20,000 items.
    private struct Labels: Sendable {
        let now, yesterday: String
        let minutes, hours, days: CountLabel

        init(_ language: AppLanguage) {
            now = L10n.string("time.now", language)
            yesterday = L10n.string("time.yesterday", language)
            minutes = CountLabel(L10n.string("time.minutes", language), locale: language.locale)
            hours = CountLabel(L10n.string("time.hours", language), locale: language.locale)
            days = CountLabel(L10n.string("time.days", language), locale: language.locale)
        }
    }

    /// A label with one count ("%lldm", "%lld Min."): the text around its `%lld`, joined to the number as `%lld`
    /// prints it below 1,000 (no grouping separator yet); any other template or count is formatted.
    private struct CountLabel: Sendable {
        let template: String
        let locale: Locale
        let around: (before: String, after: String)?

        init(_ template: String, locale: Locale) {
            self.template = template
            self.locale = locale
            around = ["%lld", "%1$lld"].lazy.compactMap { token -> (String, String)? in
                guard let range = template.range(of: token) else { return nil }
                let before = String(template[..<range.lowerBound]), after = String(template[range.upperBound...])
                return before.contains("%") || after.contains("%") ? nil : (before, after)
            }.first
        }

        func callAsFunction(_ count: Int) -> String {
            guard let around, (0..<1000).contains(count) else { return String(format: template, locale: locale, count) }
            return around.before + String(count) + around.after
        }
    }

    private static let labels = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map { ($0, Labels($0)) })

    public static func string(from date: Date, now: Date, language: AppLanguage) -> String {
        let labels = labels[language] ?? Labels(language)
        let elapsed = max(0, now.timeIntervalSince(date))
        switch elapsed {
        case ..<60:
            return labels.now
        case ..<3600:
            return labels.minutes(Int(elapsed / 60))
        case ..<86_400:
            return labels.hours(Int((elapsed / 3600).rounded()))
        case ..<172_800:
            return labels.yesterday
        default:
            return labels.days(Int((elapsed / 86_400).rounded()))
        }
    }
}

public enum NumberFormatting {
    public static func count(_ value: Int, language: AppLanguage) -> String {
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// Languages named in the app's language: "en" is "İngilizce" in Turkish, "English" in English.
public enum LanguageNames {
    /// A BCP-47 code's language, by its language code; a code no locale knows is shown as it is.
    public static func name(_ code: String, in language: AppLanguage) -> String {
        Locale(identifier: language.rawValue).localizedString(forLanguageCode: code) ?? code
    }

    /// "İngilizce → Türkçe".
    public static func pair(from: String, to: String, in language: AppLanguage) -> String {
        "\(name(from, in: language)) → \(name(to, in: language))"
    }
}
