import Foundation
import YabCore
import YabExtensionKit
import YabExtensions
import YabLocalization

/// What one row of the job card says. A status line reads state, then
/// subject, then numbers, and only the subject is ever cut (the State-First Line Rule): with a
/// fraction the extension's message is the numbers after the subject; without one it is the
/// state word before it. A finished row names its result and where it went; a failed one says
/// why, app-made failures in the app's language.
///
/// The job's subject and messages are the person's content: shown, never logged.
public struct JobRowPresentation {
    /// How the row is drawn: a waiting title is quieter, a finished tile reads in full text color,
    /// and a failure trades the bar for its message.
    public enum Style: Sendable, Equatable { case queued, running, finished, failed }

    public let style: Style
    /// As commands name theirs: "sf:<SF Symbol>" or an image's path. While at work, the command's
    /// own; `checkmark` when done, `clipboard` when ready (the outline of a paste
    /// glyph; `doc.on.clipboard` drew a solid sheet among outline icons), `exclamationmark.circle`
    /// when failed.
    public let icon: String
    /// The action's title; a failed row's is the action's own failure title when it has one.
    public let title: String
    /// Drawn as keycaps where they stand in `title` ("⌘", "V" in "Hazır, ⌘V ile yapıştır").
    public let titleKeys: [String]
    /// The share done, in the app's language ("%42", "42%"); only while a fraction is known.
    public let percent: String?
    /// `subject` is the job's short subject (`shortSubject`); for a finished job, its result's name
    /// in full; for a failed one, "<short subject>: <reason>", which may take up to three lines.
    public let status: (head: String?, subject: String, tail: String?)
    /// Waiting and running rows show the bar; a finished row keeps its space, a failed one gives it up.
    public let showsBar: Bool
    public let fraction: Double?
    public let isIndeterminate: Bool
    /// "<action>, <subject>, <state>".
    public let accessibilityLabel: String
    /// The ✕: "İptal: <action>, <subject>" while the job waits or runs, "Kapat: …" once it ended.
    public let buttonLabel: String

    /// The ✕ stops a waiting or running job; on a finished or failed row it closes the card.
    public var cancels: Bool { style == .queued || style == .running }

    public static func make(_ job: JobCenter.Job, language: AppLanguage) -> JobRowPresentation {
        let action = job.command.title
        let subject = Self.shortSubject(job.subjectTitle)
        let message = job.message.flatMap(nonEmpty)
        let style: Style, icon: String, title: String, titleKeys: [String]
        var percent: String?, status: (head: String?, subject: String, tail: String?), state: String
        var fraction: Double?, isIndeterminate = false

        switch job.phase {
        case .queued:
            (style, icon, title, titleKeys) = (.queued, job.command.icon, action, [])
            state = L10n.string("jobs.queued", language)
            status = (state, subject, nil)
        case .running:
            (style, icon, title, titleKeys) = (.running, job.command.icon, action, [])
            if let known = job.fraction {
                let share = min(1, max(0, known))
                let text = share.formatted(.percent.precision(.fractionLength(0)).locale(language.locale))
                (fraction, percent, state) = (share, text, text)
                status = (nil, subject, message)
            } else {
                isIndeterminate = true
                state = message ?? L10n.string("jobs.starting", language)
                status = (state, subject, nil)
            }
        case .done, .ready, .superseded:
            // The file's own name, in full.
            let result = job.resultName.flatMap(nonEmpty) ?? subject
            if job.phase == .ready {
                titleKeys = ["⌘", "V"]
                (icon, title) = ("sf:clipboard", L10n.string("jobs.ready", language, titleKeys.joined()))
            } else {
                (icon, title, titleKeys) = ("sf:checkmark", Self.finishedTitle(job, language), [])
            }
            style = .finished
            state = title
            status = (nil, result, nil)
        case .failed:
            (style, icon, title, titleKeys) = (.failed, "sf:exclamationmark.circle", job.command.failTitle ?? action, [])
            state = Self.failure(code: job.errorCode, message: job.errorMessage, language)
            // Tied to its item: "<subject>: <reason>".
            status = (nil, "\(subject): \(state)", nil)
        }

        let atWork = style == .queued || style == .running
        let button = L10n.string(atWork ? "jobs.cancel" : "jobs.close", language)
        return JobRowPresentation(style: style, icon: icon, title: title, titleKeys: titleKeys, percent: percent, status: status,
                                  showsBar: atWork, fraction: fraction, isIndeterminate: isIndeterminate,
                                  accessibilityLabel: "\(action), \(subject), \(state)", buttonLabel: "\(button): \(action), \(subject)")
    }

    /// Where a done result went: onto the Sıra, into Finder, or pasted into another app.
    private static func finishedTitle(_ job: JobCenter.Job, _ language: AppLanguage) -> String {
        switch job.phase {
        case .superseded: return L10n.string("jobs.superseded", language)
        default:
            if job.delivery == .stacked { return L10n.string("jobs.done.stack", language) }
            return job.target?.kind == .finder ? L10n.string("jobs.done.finder", language) : L10n.string("jobs.done.pasted", language)
        }
    }

    /// Why a job failed. Failures the app or its host made carry English text, so the card words
    /// them itself; a script's own error is already in the person's language. A result that is not
    /// one (`badResult`) is the app's finding: generic here, its reason in the Development log.
    static func failure(code: ExtensionError.Code?, message: String?, _ language: AppLanguage) -> String {
        let message = message.flatMap(nonEmpty)
        let generic = L10n.string("jobs.failed.generic", language)
        switch code {
        case .toolMissing:
            if let tool = message.flatMap(missingTool) { return L10n.string("jobs.failed.toolMissing", language, tool) }
            return message ?? generic
        case .interrupted: return L10n.string("jobs.failed.interrupted", language)
        case .unavailable: return L10n.string("jobs.failed.unavailable", language)
        case .networkError: return L10n.string("jobs.failed.network", language)
        case .permissionDenied: return L10n.string("jobs.failed.permission", language)
        case .script, nil: return message ?? generic
        case .badResult, .timeout, .syntax, .notFound, .unsupported, .cancelled: return generic
        }
    }

    /// The subject as the card's status lines and the status menu name it: on one line (a copied
    /// text's line breaks would cut it short), without a " — …" tail ("SwiftUI ile Liquid Glass —
    /// tam rehber" → "SwiftUI ile Liquid Glass").
    public static func shortSubject(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        let short = line.replacing(/\s+—.*$/, with: "")
        return short.isEmpty ? line : short
    }

    /// What a job started on an item is called: what the panel's row shows for it, except that a
    /// link without a page title (its preview is still its address) names itself (`LinkSubject`).
    public static func subjectTitle(kind: ItemKind, previewText: String) -> String {
        guard kind == .link else { return previewText }
        return LinkSubject.name(of: previewText) ?? previewText
    }

    /// The tool in ExecAPI's "<name> is not installed[. Install it with: …]".
    static func missingTool(in message: String) -> String? {
        guard let range = message.range(of: " is not installed") else { return nil }
        let name = message[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
