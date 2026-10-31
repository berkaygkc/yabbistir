/// One row of a source's listing, as the host let it through: short plain text on one line each, the id as the
/// extension gave it (`run` gets it back). Lives in the app's memory only: never in history, the search index or on disk.
public struct SourceRow: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?

    public init(id: String, title: String, subtitle: String? = nil) {
        (self.id, self.title, self.subtitle) = (id, title, subtitle)
    }
}

/// What a source's `list` answered: its rows, or that it is locked and how the person unlocks it.
public enum SourceListing: Codable, Equatable, Sendable {
    case rows([SourceRow])
    /// `command`: a line the person runs to unlock it (⌘C copies it).
    case locked(message: String, command: String?)
}

/// What a source's row action gave: a secret (a password) or plain text. It travels from the extension to the
/// clipboard and nowhere else: it never prints itself, not even to a debugger or a failing test, so no log line, error
/// message or notice can carry it by accident.
public enum SourceValue: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case secret(String)
    case text(String)

    /// Empty, or spaces and line ends only: never pasted or copied.
    public var isBlank: Bool {
        switch self {
        case .secret(let value), .text(let value): value.allSatisfy(\.isWhitespace)
        }
    }

    public var description: String {
        switch self {
        case .secret: "SourceValue.secret(<redacted>)"
        case .text: "SourceValue.text(<redacted>)"
        }
    }

    public var debugDescription: String { description }

    /// No children: `dump` and anything else that walks a value's mirror finds no string inside.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}

/// Which row and action a `sourceRun` is for, and what the manifest says the action gives (the host refuses anything
/// else).
public struct SourceInvocation: Codable, Equatable, Sendable {
    public var rowID: String
    public var actionID: String
    public var kind: SourceActionSpec.Kind

    public init(rowID: String, actionID: String, kind: SourceActionSpec.Kind) {
        (self.rowID, self.actionID, self.kind) = (rowID, actionID, kind)
    }
}
