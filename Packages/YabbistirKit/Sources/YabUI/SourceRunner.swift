import YabExtensionKit
import YabExtensions
import YabPasteboard

/// Where a source row's action runs: `SourceCenter`; tests use a fake.
@MainActor
public protocol SourceRunning: AnyObject {
    func run(_ key: String, row: String, action: String) async throws(ExtensionError) -> SourceValue
}

extension SourceCenter: SourceRunning {}

/// The one way a source's value reaches the clipboard: the action runs, a blank value stops there, a secret is pasted
/// concealed (its clipboard given back), text is pasted or copied. Nothing here keeps the value or logs it, and the
/// notice it answers with says what happened, never what was pasted.
@MainActor
public final class SourceRunner {
    private let sources: SourceRunning
    private let paste: SensitivePasting

    public init(sources: SourceRunning, paste: SensitivePasting) {
        self.sources = sources
        self.paste = paste
    }

    /// Runs one action and pastes or copies its value; returns the notice to show, if any.
    /// `copy`: ⌘C, which only a text action takes; a secret is never copied, so it is not even asked for.
    public func run(_ descriptor: SourceDescriptor, row: String, action: String, copy: Bool,
                    target: String?, onlyIf: (() -> Bool)?, restoreInstead: (() -> Void)?) async -> NoticeKind? {
        let spec = descriptor.actions.first { $0.id == action }
        if copy, spec?.kind == .secret { return nil }
        let value: SourceValue
        do throws(ExtensionError) {
            value = try await sources.run(descriptor.id, row: row, action: action)
        } catch {
            return .extensionFailed(name: descriptor.extensionName, message: error.message)
        }
        guard !value.isBlank else { return .sourceEmpty }
        switch value {
        case .secret where copy:
            // A copy has no concealed path: a secret that came back for one goes nowhere.
            return nil
        case .secret(let secret):
            switch await paste.paste(secret, concealed: true, targetBundleID: target, onlyIf: onlyIf, restoreInstead: restoreInstead) {
            case .pasted: return .sourcePasted
            case .copiedOnly(.targetLeft): return .sourceNotPasted
            case .copiedOnly: return .secretCopiedOnly
            }
        case .text(let text) where copy:
            paste.copy(text)
            return .sourceCopied(message: spec?.copied)
        case .text(let text):
            // As an item's paste: in the field, nothing to say; otherwise it waits on the clipboard for ⌘V.
            switch await paste.paste(text, concealed: false, targetBundleID: target, onlyIf: onlyIf, restoreInstead: restoreInstead) {
            case .pasted: return nil
            case .copiedOnly(.accessibilityDenied), .copiedOnly(.keyNotResolvable): return .accessibility
            case .copiedOnly(.secureInput): return .secureInput
            case .copiedOnly(.targetLeft): return .copiedOnly
            }
        }
    }

    /// The locked row's ⌘C: its unlock command, to the clipboard as text that never joins history.
    public func copyCommand(_ command: String) -> NoticeKind {
        paste.copy(command)
        return .sourceCommandCopied
    }
}
