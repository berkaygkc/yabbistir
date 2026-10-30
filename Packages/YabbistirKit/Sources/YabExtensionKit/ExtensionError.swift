/// Why a call into an extension failed. Crosses the host protocol as JSON.
public struct ExtensionError: Error, Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        /// The script threw.
        case script
        /// index.js does not parse.
        case syntax
        case timeout
        /// No such extension, action or detector.
        case notFound
        /// The script returned something that is not a result.
        case badResult
        /// The host or the native capability is not available (restarting, WebP writer missing …).
        case unavailable
        /// The extension needs something this version does not offer.
        case unsupported
        /// Cut short by something else: another call's timeout restarted the host, or the host
        /// stopped. Never counted against the extension.
        case interrupted
        /// The extension used a capability its manifest does not declare or the person has not allowed.
        case permissionDenied
        /// A tool named in `requires.tools` is not installed.
        case toolMissing
        /// The person cancelled the job.
        case cancelled
        /// A request failed on the network.
        case networkError
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}
