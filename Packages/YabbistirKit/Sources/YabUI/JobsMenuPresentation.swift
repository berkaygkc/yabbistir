import AppKit
import YabExtensions
import YabLocalization

/// The status item menu's **Süren işler** section: one
/// "İptal: <action>" row per job that waits or runs, in the order they started, with the job's
/// short subject after it. It is the keyboard and VoiceOver route to cancelling, since the card
/// never takes focus. Finished and failed cards are closed on the card itself.
///
/// Subjects are the person's content: shown, never logged.
public enum JobsMenuPresentation {
    public struct Row: Equatable, Sendable {
        public let jobID: Int
        /// "İptal: Video olarak indir".
        public let title: String
        /// The short subject (`JobRowPresentation.shortSubject`), in full; the menu cuts it to fit.
        public let subject: String
        /// "İptal: <action>, <subject>", as the card's ✕ is labelled.
        public let accessibilityLabel: String
    }

    public struct Section: Equatable, Sendable {
        public let title: String
        public let rows: [Row]
    }

    /// How wide a row's subject may run before it is cut, so the menu keeps a steady measure.
    public static let subjectWidth: CGFloat = 150

    /// Nil when nothing waits or runs: the menu leaves the section out.
    public static func section(for jobs: [JobCenter.Job], language: AppLanguage) -> Section? {
        let rows = jobs.filter { $0.phase == .queued || $0.phase == .running }.map { job in
            let action = job.command.title
            let subject = JobRowPresentation.shortSubject(job.subjectTitle)
            return Row(jobID: job.id, title: L10n.string("jobs.menu.cancel", language, action), subject: subject,
                       accessibilityLabel: "\(L10n.string("jobs.cancel", language)): \(action), \(subject)")
        }
        return rows.isEmpty ? nil : Section(title: L10n.string("jobs.menu.section", language), rows: rows)
    }

    /// `text` cut at the end with "…" so it fits `width` in `font`; whole when it already fits.
    public static func truncated(_ text: String, toWidth width: CGFloat, font: NSFont) -> String {
        func fits(_ candidate: String) -> Bool { (candidate as NSString).size(withAttributes: [.font: font]).width <= width }
        guard !fits(text) else { return text }
        let characters = Array(text)
        // The longest head that fits with its ellipsis.
        var (low, high) = (0, characters.count)
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(String(characters[..<middle]).trimmingCharacters(in: .whitespaces) + "…") { low = middle } else { high = middle - 1 }
        }
        return String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
