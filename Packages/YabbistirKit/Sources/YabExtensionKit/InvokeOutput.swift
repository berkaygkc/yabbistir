/// What a call into an extension produced, by the kind of call.
public enum InvokeOutput: Codable, Equatable, Sendable {
    /// `run`: an action's result.
    case result(ExtensionResult)
    /// `validate`: whether a detector keeps its tag.
    case valid(Bool)
    /// `preview`: blocks for the item's preview.
    case sections([PreviewSection])
    /// `captureRule`: what the rule decided about a new copy.
    case capture(CaptureOutcome)
}
