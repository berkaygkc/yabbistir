import Foundation
import YabCore

/// The item kinds ⇧↵ keeps a separate default for; code shares the text default.
public enum ShiftKind: String, CaseIterable, Sendable {
    case text, link, color, image, file

    public init(_ kind: ItemKind) {
        switch kind {
        case .text, .code: self = .text
        case .link: self = .link
        case .color: self = .color
        case .image: self = .image
        case .file: self = .file
        }
    }
}

public enum ShiftReturnAction: Equatable, Sendable {
    case paste
    case plainText
    case command(String)
}

public enum ShiftReturn {
    public static let plainTextID = "yabbistir/plain"

    /// A pinned default wins while it still applies; otherwise rich text pastes as plain text and
    /// everything else pastes as it is, so ⇧↵ never runs a transform the user did not choose.
    /// `transforms`: the ⇧ panel's command ids for this item, in panel order (already filtered for the target).
    public static func resolve(isRich: Bool, transforms: [String], pinned: String?) -> ShiftReturnAction {
        if let pinned {
            if pinned == plainTextID {
                if isRich { return .plainText }
            } else if transforms.contains(pinned) {
                return .command(pinned)
            }
        }
        return isRich ? .plainText : .paste
    }
}

/// The user's pinned ⇧↵ default per item kind.
@MainActor
public final class ShiftReturnDefaults {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ kind: ShiftKind) -> String { "shiftReturn.default.\(kind.rawValue)" }

    public func pinned(for kind: ShiftKind) -> String? {
        defaults.string(forKey: key(kind))
    }

    /// `nil` removes the pin.
    public func pin(_ id: String?, for kind: ShiftKind) {
        if let id { defaults.set(id, forKey: key(kind)) } else { defaults.removeObject(forKey: key(kind)) }
    }
}
