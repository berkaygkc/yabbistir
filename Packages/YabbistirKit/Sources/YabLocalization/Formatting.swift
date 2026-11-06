import Foundation

/// Compact "time since copied" labels for list rows: now · 4m · 2h · yesterday · 6d.
public enum ShortRelativeTime {
    public static func string(from date: Date, now: Date, language: AppLanguage) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        switch elapsed {
        case ..<60:
            return L10n.string("time.now", language)
        case ..<3600:
            return L10n.string("time.minutes", language, Int(elapsed / 60))
        case ..<86_400:
            return L10n.string("time.hours", language, Int((elapsed / 3600).rounded()))
        case ..<172_800:
            return L10n.string("time.yesterday", language)
        default:
            return L10n.string("time.days", language, Int((elapsed / 86_400).rounded()))
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
