import Foundation

/// Compact "time since copied" labels for list rows: now · 4m · 2h · yesterday · 6d.
public enum ShortRelativeTime {
    public static func string(from date: Date, now: Date, language: AppLanguage) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        let turkish = language == .turkish
        switch elapsed {
        case ..<60:
            return turkish ? "şimdi" : "now"
        case ..<3600:
            let minutes = Int(elapsed / 60)
            return turkish ? "\(minutes) dk" : "\(minutes)m"
        case ..<86_400:
            let hours = Int((elapsed / 3600).rounded())
            return turkish ? "\(hours) sa" : "\(hours)h"
        case ..<172_800:
            return turkish ? "dün" : "yesterday"
        default:
            let days = Int((elapsed / 86_400).rounded())
            return turkish ? "\(days) gün" : "\(days)d"
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
