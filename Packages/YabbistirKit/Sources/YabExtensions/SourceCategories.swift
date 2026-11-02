import Foundation
import YabCore

/// Every usable extension's source opens its own category: made when the extension is turned on, renamed with
/// the source, removed when the extension goes or is turned off.
public enum SourceCategories {
    /// Never call this before the registry has scanned: an empty list would remove every source category.
    @MainActor public static func sync(library: Library, sources: [SourceDescriptor]) {
        // A failure leaves the categories as they were; the next change of extensions tries again.
        try? library.syncSourceCategories(sources.map { SourceCategorySeed(key: $0.id, name: $0.title) })
    }
}
