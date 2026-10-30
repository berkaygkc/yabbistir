import Foundation

/// Folds text for search so Turkish and English spellings find each other:
/// İ/I/ı all become "i", case and diacritics are dropped (ş→s, ğ→g, ü→u …).
public enum SearchNormalizer {
    public static func normalize(_ s: String) -> String {
        var mapped = String()
        mapped.reserveCapacity(s.utf8.count)
        for character in s {
            switch character {
            case "İ", "I", "ı": mapped.append("i")
            default: mapped.append(character)
            }
        }
        return mapped.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
