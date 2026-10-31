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
