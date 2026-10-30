/// What a capture rule decided about a new copy.
public enum CaptureOutcome: Codable, Equatable, Sendable {
    /// Store the copy as it is.
    case keep
    /// Do not store the copy at all.
    case ignore
    /// Store plain text instead (text and link items only).
    case replaceText(String)
    /// Store this link instead (text and link items only).
    case replaceURL(String)
    /// Store the copy and put it in the category with this name, when one exists.
    case addToCategory(String)
}
