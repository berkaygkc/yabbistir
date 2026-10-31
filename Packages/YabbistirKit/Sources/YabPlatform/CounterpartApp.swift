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

    /// The other build's running copies that this copy asks to quit as it starts: only those launched before it. When
    /// both start within a moment of each other, the one launched later asks the earlier one, never the other way.
    public static func copiesToReplace(own: RunningCopy, running: [RunningCopy]) -> [RunningCopy] {
        guard let other = counterpart(of: own.bundleID) else { return [] }
        return running.filter { $0.bundleID == other && launchedBefore($0, own) }
    }

    /// Whether this copy should quit because the other build appears among `added`: only for one launched after it.
    public static func shouldQuit(own: RunningCopy, added: [RunningCopy]) -> Bool {
        guard let other = counterpart(of: own.bundleID) else { return false }
        return added.contains { $0.bundleID == other && launchedBefore(own, $0) }
    }

    /// Whether `first` was launched before `second`. The launch dates decide; when one is unknown or both are the
    /// same, the process ID does (a later launch gets a higher one). Of two copies, exactly one is the earlier.
    static func launchedBefore(_ first: RunningCopy, _ second: RunningCopy) -> Bool {
        if let one = first.launchDate, let two = second.launchDate, one != two { return one < two }
        return first.processID < second.processID
    }
}

/// One running copy of yabbistir: which build it is and when it was launched.
public struct RunningCopy: Equatable, Sendable {
    public let bundleID: String
    /// Nil when launch services does not know it (a copy not started through it).
    public let launchDate: Date?
    public let processID: Int32

    public init(bundleID: String, launchDate: Date?, processID: Int32) {
        (self.bundleID, self.launchDate, self.processID) = (bundleID, launchDate, processID)
    }
}
