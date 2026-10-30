import AppKit
import SwiftUI
import YabExtensions
import YabLocalization

/// Long-running jobs under the menu bar status item: a 320 pt glass card
/// built from the panel's grey parts. Each row is a 28 pt tile, the action with a slot its percent
/// and ✕ share, a 3 pt neutral bar and one state-first status line. The card never takes focus;
/// its only controls are the ✕ buttons, and the status item's menu is the keyboard and VoiceOver
/// route to cancelling.
public struct JobCardView: View {
    let jobs: [JobCenter.Job]
    let language: AppLanguage
    let onCancel: (Int) -> Void
    let onDismiss: (Int) -> Void
    /// Snapshot rendering: ImageRenderer draws no glass, and the indeterminate bar holds still.
    var snapshot = false

    public static let width: CGFloat = 320
    static let radius: CGFloat = 14

    /// `onCancel` stops a waiting or running job; `onDismiss` closes a finished or failed card.
    public init(jobs: [JobCenter.Job], language: AppLanguage, onCancel: @escaping (Int) -> Void, onDismiss: @escaping (Int) -> Void) {
        self.jobs = jobs
        self.language = language
        self.onCancel = onCancel
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                let row = JobRowPresentation.make(job, language: language)
                JobRowView(row: row, still: snapshot) { row.cancels ? onCancel(job.id) : onDismiss(job.id) }
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5).padding(.horizontal, 10) }
                    }
                    .transition(JobRowTransition())
            }
        }
        .padding(4)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // A row's height collapses as it comes or goes, and the card follows.
        .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.28)), value: jobs.map(\.id))
        .background(PanelBackground(material: PanelMaterial.current, cornerRadius: Self.radius, forceSolid: snapshot))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("jobs.card", language))
        .environment(\.locale, language.locale)
    }
}

/// One job: tile · title line (title, percent/✕ slot) · bar · status line. A finished row hides the
/// bar but keeps its place, so its height holds; a failed row gives the bar's place to its reason.
private struct JobRowView: View {
    let row: JobRowPresentation
    let still: Bool
    let action: () -> Void
    @State private var hovering = false

    /// 11.5 pt type on a 15 pt line (Status type). SwiftUI sets the face on a whole-point line (14).
    static let statusFont = Font.system(size: 11.5)
    static let statusLineSpacing: CGFloat = {
        let font = NSFont.systemFont(ofSize: 11.5)
        return max(0, 15 - (font.ascender - font.descender + font.leading).rounded(.up))
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            tile
            VStack(alignment: .leading, spacing: 0) {
                titleLine
                if row.style == .failed {
                    reason
                } else {
                    JobBar(fraction: row.fraction, isIndeterminate: row.isIndeterminate, still: still)
                        .padding(.top, 7)
                        .padding(.bottom, 6)
                        .opacity(row.showsBar ? 1 : 0)
                    statusLine
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Tokens.Colors.tile)
            .frame(width: 28, height: 28)
            .overlay {
                CommandIcon(icon: row.icon, size: 12, color: row.style == .finished ? Tokens.Colors.text : Tokens.Colors.textSecondary)
            }
            .accessibilityHidden(true)
    }

    // MARK: Title line

    private var titleLine: some View {
        HStack(spacing: 8) {
            title
                .font(row.style == .queued ? .system(size: 12.5, weight: .medium) : Tokens.Fonts.labelStrong)
                .foregroundStyle(row.style == .queued ? Tokens.Colors.textSecondary : Tokens.Colors.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            slot
        }
        .frame(height: 18)
    }

    /// The title, with its keys ("⌘V") drawn as 18 pt keycaps where they stand.
    @ViewBuilder private var title: some View {
        let keys = row.titleKeys.joined()
        if !keys.isEmpty, let range = row.title.range(of: keys) {
            HStack(spacing: 5) {
                Text(row.title[..<range.lowerBound].trimmingCharacters(in: .whitespaces))
                ForEach(row.titleKeys, id: \.self) { Keycap($0, size: 18, font: .system(size: 11, weight: .medium)) }
                Text(row.title[range.upperBound...].trimmingCharacters(in: .whitespaces))
            }
        } else {
            Text(row.title)
        }
    }

    /// The percent and the ✕ share one place: hovering the row trades one for the other
    /// (0.12 s); a failed row's ✕ always shows.
    private var slot: some View {
        let showsButton = hovering || row.style == .failed
        return ZStack(alignment: .trailing) {
            Text(row.percent ?? "")
                .font(Tokens.Fonts.label)
                .monospacedDigit()
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .opacity(showsButton ? 0 : 1)
            JobRowButton(label: row.buttonLabel, action: action)
                .opacity(showsButton ? 1 : 0)
                .allowsHitTesting(showsButton)
        }
        .frame(minWidth: 34, alignment: .trailing)
        .animation(Tokens.Motion.resolved(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.12)), value: showsButton)
    }

    // MARK: Status

    /// State, then subject, then numbers; only the subject is ever cut.
    private var statusLine: some View {
        HStack(spacing: 0) {
            if let head = row.status.head { Text(verbatim: "\(head) · ").fixedSize() }
            Text(row.status.subject).lineLimit(1).truncationMode(.tail)
            if let tail = row.status.tail { Text(verbatim: " · \(tail)").fixedSize() }
        }
        .font(Self.statusFont)
        .monospacedDigit()
        .foregroundStyle(Tokens.Colors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 15)
    }

    /// Why it failed, on up to three lines in the bar's place. Half the line spacing above and below
    /// gives every line the 15 pt a single status line has.
    private var reason: some View {
        Text(row.status.subject)
            .font(Self.statusFont)
            .lineSpacing(Self.statusLineSpacing)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4 + Self.statusLineSpacing / 2)
            .padding(.bottom, Self.statusLineSpacing / 2)
    }
}

/// The 18 pt round ✕: `keycap-fill` with a 0.5 pt edge, `selection` on hover.
private struct JobRowButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Tokens.Colors.text)
                .frame(width: 18, height: 18)
                .background(hovering ? Tokens.Colors.selection : Tokens.Colors.keycapFill, in: Circle())
                .overlay(Circle().strokeBorder(Tokens.Colors.edge, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

/// 3 pt, `tile` track, `text-secondary` fill easing 0.3 s linear. Unknown progress is a 34% segment
/// sliding across in 1.3 s; with Reduce Motion it rests in the middle.
struct JobBar: View {
    let fraction: Double?
    let isIndeterminate: Bool
    let still: Bool
    @State private var start = Date()

    private static let segment: CGFloat = 0.34
    private static let slide = 1.3
    private static let curve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.16, y: 1), endControlPoint: UnitPoint(x: 0.3, y: 1))

    /// The sliding segment redraws at most 30 times a second: smooth enough for a 1.3 s slide, and a
    /// download of unknown size does not redraw at the display's full rate for as long as it takes.
    static func schedule(paused: Bool) -> AnimationTimelineSchedule {
        .animation(minimumInterval: 1.0 / 30, paused: paused)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Tokens.Colors.tile)
                if isIndeterminate {
                    sliding(width: width)
                } else {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Tokens.Colors.textSecondary)
                        .frame(width: width * CGFloat(fraction ?? 0))
                        .animation(Tokens.Motion.resolved(.linear(duration: 0.3)), value: fraction)
                }
            }
        }
        .frame(height: 3)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .accessibilityHidden(true)
    }

    private func sliding(width: CGFloat) -> some View {
        let resting = still || Tokens.Motion.reduceMotion()
        return TimelineView(Self.schedule(paused: resting)) { context in
            let length = width * Self.segment
            // The segment slides from -105% to 300% of its own width.
            let x: CGFloat = resting ? (width - length) / 2 : {
                let t = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Self.slide) / Self.slide
                return length * (-1.05 + 4.05 * CGFloat(Self.curve.value(at: t)))
            }()
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Tokens.Colors.textSecondary)
                .frame(width: length)
                .offset(x: x)
        }
    }
}

/// Rows come and go by collapsing their height (0.28 s, from the card's animation) as they fade (0.2 s).
private struct JobRowTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        CollapsingLayout(shown: phase.isIdentity ? 1 : 0) { content }
            .clipped()
            .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.2))) { $0.opacity(phase.isIdentity ? 1 : 0) }
    }
}

/// Lays its one subview out at full height and reports a share of it, top-anchored.
private struct CollapsingLayout: Layout {
    var shown: CGFloat

    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let row = subviews.first else { return .zero }
        let size = row.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * shown)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let row = subviews.first else { return }
        let size = row.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        row.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}
