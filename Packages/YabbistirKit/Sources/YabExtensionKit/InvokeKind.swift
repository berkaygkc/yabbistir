/// Which function of an extension a call runs.
public enum InvokeKind: String, Codable, Sendable {
    /// `actions[name].run(item, ctx)`
    case run
    /// `detectors[name].validate(item)`
    case validate
    /// `detectors[name].preview(item, ctx)`
    case preview
    /// `captureRules[name].run(item, ctx)`
    case captureRule
    /// `sources[name].list(ctx)`
    case sourceList
    /// `sources[name].run(rowId, actionId, ctx)`
    case sourceRun
}

extension InvokeKind {
    /// A source's list or one of its row actions.
    public var isSource: Bool { self == .sourceList || self == .sourceRun }
}

extension ExtensionError {
    /// A source's call asked to open a link or put up a notice. Neither needs a permission, and either could carry a
    /// value out of the call (a link's address reaches a website), so the helper and the app both refuse it.
    public static let sourceCannotReachOut = ExtensionError(.permissionDenied, "a source cannot open links or show notices")
}
