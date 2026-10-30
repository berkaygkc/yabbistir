import Foundation
import FoundationModels
import YabExtensionKit

/// The on-device language model, as the app uses it for `yab.ai.generate`; tests put a fake in its place.
public protocol LanguageModelService: Sendable {
    func availability() -> AIAvailabilityState
    /// The model's answer to `prompt`. Stops, throwing, when the calling task is cancelled.
    func respond(_ prompt: String, options: AIOptions) async throws -> String
}

/// Apple Intelligence's on-device model (FoundationModels). Each answer gets a session of its own, so
/// one extension's prompts never colour another's. Nothing here logs a prompt or an answer.
public struct OnDeviceAI: LanguageModelService {
    /// `yab.ai` transforms the person's own text (summarize, rewrite): with these guardrails a text answer
    /// is not refused for what that text contains (no `guardrailViolation` for String output). Whether it
    /// can run is read from this same model.
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    public init() {}

    public func availability() -> AIAvailabilityState {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.device)
            case .appleIntelligenceNotEnabled: return .unavailable(.disabled)
            case .modelNotReady: return .unavailable(.notReady)
            // A reason a later macOS adds: most likely passing, like the model getting ready.
            @unknown default: return .unavailable(.notReady)
            }
        }
    }

    public func respond(_ prompt: String, options: AIOptions) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: options.instructions)
        let generation = GenerationOptions(temperature: options.temperature, maximumResponseTokens: options.maxTokens)
        return try await session.respond(to: prompt, options: generation).content
    }
}
