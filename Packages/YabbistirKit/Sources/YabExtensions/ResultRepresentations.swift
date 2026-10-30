import Foundation
import YabCore
import YabExtensionKit

/// An action's result as clipboard representations (one pasteboard item).
public enum ResultRepresentations {
    public static let html = "public.html"

    private static func fileRepresentation(_ path: String) -> PasteboardRepresentation {
        PasteboardRepresentation(type: TypeIdentifiers.fileURL, data: Data(URL(fileURLWithPath: path).absoluteString.utf8))
    }

    /// `file`: an image result's copy on disk; its URL rides along so Finder pastes a file.
    public static func make(_ result: ExtensionResult, file: URL? = nil) -> [[PasteboardRepresentation]] {
        func representation(_ type: String, _ text: String) -> PasteboardRepresentation {
            PasteboardRepresentation(type: type, data: Data(text.utf8))
        }
        switch result {
        case .text(let text):
            return [[representation(TypeIdentifiers.plainText, text)]]
        case .html(let html, let text):
            return [[representation(Self.html, html), representation(TypeIdentifiers.plainText, text)]]
        case .image(let data, let uti, _, _):
            // Only the format asked for: a PNG copy beside a JPEG is what the target would take.
            var item = [PasteboardRepresentation(type: uti, data: data)]
            if let file { item.append(representation(TypeIdentifiers.fileURL, file.absoluteString)) }
            return [item]
        case .link(let url, let title):
            var item = [representation(TypeIdentifiers.url, url), representation(TypeIdentifiers.plainText, url)]
            if let title { item.append(representation(TypeIdentifiers.urlName, title)) }
            return [item]
        case .none:
            return []
        case .file(let path):
            return [[fileRepresentation(path)]]
        case .files(let paths):
            // One pasteboard item per file, as Finder puts several files on the pasteboard.
            return paths.map { [fileRepresentation($0)] }
        }
    }
}
