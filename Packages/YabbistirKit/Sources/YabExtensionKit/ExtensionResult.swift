import Foundation

/// What an action returns. Writing it to the clipboard, pasting and adding it to history are the
/// app's job.
public enum ExtensionResult: Codable, Equatable, Sendable {
    case text(String)
    case html(html: String, text: String)
    case image(data: Data, uti: String, width: Int, height: Int)
    case link(url: String, title: String?)
    case file(path: String)
    case files(paths: [String])
    case none(message: String?)
}

/// A block a detector adds to the preview; the app draws it.
public enum PreviewSection: Codable, Equatable, Sendable {
    case keyValue(title: String, rows: [[String]])
    case text(title: String, text: String)
    case code(title: String, code: String, language: String?)
    case image(title: String, data: Data)
    case link(title: String, url: String)
}
