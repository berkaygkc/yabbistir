import Foundation

/// The release and the Debug build have different bundle IDs but share one history, so only one of them may run at
/// a time. This maps each ID to the other's.
public enum CounterpartApp {
    public static let releaseID = "dev.yabbistir.app"
    public static let debugID = "dev.yabbistir.app.debug"

    /// The bundle ID of the other build, or nil for an ID that is neither.
    public static func counterpart(of bundleID: String) -> String? {
        switch bundleID {
        case releaseID: debugID
        case debugID: releaseID
        default: nil
        }
    }

    /// Whether a running copy with `ownID` should quit because the other build appears among `added`.
    public static func shouldQuit(ownID: String, added: [String]) -> Bool {
        guard let other = counterpart(of: ownID) else { return false }
        return added.contains(other)
    }
}
