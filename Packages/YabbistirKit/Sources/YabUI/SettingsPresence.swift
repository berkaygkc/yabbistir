import Observation

/// Whether the Settings window is on screen, and how often it came forward: pages that read the system
/// (permissions, the login item, disk usage) poll or refresh from this rather than from their own appearance.
@MainActor @Observable
public final class SettingsPresence {
    public internal(set) var isVisible = false
    public private(set) var forwardCount = 0

    public init() {}

    public func shown() { isVisible = true }

    public func closed() { isVisible = false }

    /// A window in the Dock is not on screen: pages stop polling until it comes back.
    public func miniaturized() { isVisible = false }

    public func deminiaturized() { isVisible = true }

    public func cameForward() { forwardCount += 1 }
}
