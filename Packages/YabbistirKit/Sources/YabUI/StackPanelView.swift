import AppKit
import SwiftUI
import YabCore
import YabLocalization
import YabStack

/// The Sıra window in the panel's own language: one-line 40 pt
/// rows with keycap numbers, the next one on the grey selection fill, row actions on hover. The
/// header and footer move the window; rows drag to reorder. A copy that lands behind the head
/// gets a two-line rail offering ⌥1 / ⌥2 until its countdown runs out.
public struct StackPanelView: View {
    let session: StackSession
    let library: Library
    let language: AppLanguage
    let listMaxHeight: CGFloat
    @State private var dragging: Int?
    @State private var dragOffset: CGFloat = 0

    public static let width: CGFloat = 316
    private static let rowStep = Tokens.Metrics.rowHeight
    /// Longer stacks scroll inside `listMaxHeight` (at most this, less on short screens).
    public static let defaultListMaxHeight: CGFloat = 420

    public init(session: StackSession, library: Library, language: AppLanguage, listMaxHeight: CGFloat = defaultListMaxHeight) {
        self.session = session
        self.library = library
        self.language = language
        self.listMaxHeight = listMaxHeight
    }

    public var body: some View {
        let rows = rowModels
        VStack(spacing: 0) {
            header(count: rows.count)
            Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5)
            if rows.isEmpty { emptyState } else { list(rows) }
            rail(rows)
            footer
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // Rows, the rail and the sheet's height move together.
        .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.24)), value: rows.map(\.id))
        .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.24)), value: session.recentEntryID)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Metrics.panelRadius, style: .continuous))
        .background(PanelBackground(material: PanelMaterial.current))
        .environment(\.locale, language.locale)
    }

    private var rowModels: [StackRow] {
        let entries = session.entries
        let summaries = Dictionary(library.summaries(ids: entries.map(\.itemID)).map { ($0.id, $0) }) { first, _ in first }
        return entries.enumerated().compactMap { index, entry in
            guard let summary = summaries[entry.itemID] else { return nil }
            let title = String(summary.previewText.prefix(160)).replacingOccurrences(of: "\n", with: " ")
            // The source app is a hint: a long name gives way to the title.
            let source = (summary.sourceName ?? (summary.device == .remote ? "iPhone" : nil))
                .map { $0.count > 18 ? $0.prefix(17) + "…" : $0 }
            return StackRow(id: entry.id, number: index + 1, title: title, isCode: summary.kind == .code, source: source)
        }
    }

    // MARK: Header, empty state, footer

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            Text(L10n.string("stack.title", language))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Colors.text)
            Spacer(minLength: 8)
            if count > 0 {
                Text(L10n.string("stack.count", language, "\(count)"))
                    .font(Tokens.Fonts.label)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .contentTransition(.numericText())
            }
        }
        .allowsHitTesting(false)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(WindowDragArea())
    }

    private var emptyState: some View {
        Text(L10n.string("stack.emptyHint", language))
            .font(Tokens.Fonts.body)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 20)
    }

    /// Like the panel's action bar: the key on the left, the primary action on the right.
    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Keycap("⌘")
                    Keycap("V")
                }
                Text(L10n.string("stack.footer.pasteNext", language)).lineLimit(1).fixedSize()
            }
            .font(Tokens.Fonts.label)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .allowsHitTesting(false)
            Spacer(minLength: 8)
            Button(action: session.finish) {
                Text(L10n.string("stack.done", language))
                    .font(Tokens.Fonts.labelStrong)
                    .foregroundStyle(Tokens.Colors.text)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ActionButtonStyle())
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(height: Tokens.Metrics.footerHeight)
        .background(WindowDragArea())
        .background(Tokens.Colors.footerTint)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5) }
    }

    // MARK: Rows

    @ViewBuilder
    private func list(_ rows: [StackRow]) -> some View {
        let course = VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                StackRowView(row: row, isNext: index == 0, isDragging: dragging == row.id, isSorting: dragging != nil,
                             language: language,
                             toTop: { session.move(entryID: row.id, to: 0) },
                             remove: { session.remove(entryID: row.id) })
                    .offset(y: offset(for: index, count: rows.count))
                    .zIndex(dragging == row.id ? 1 : 0)
                    .gesture(drag(row, count: rows.count))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 6)).animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.24))),
                        removal: .opacity.animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.2)))))
            }
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.24)), value: dragging == nil ? -1 : targetIndex(count: rows.count))

        if CGFloat(rows.count) * Self.rowStep + 12 > listMaxHeight {
            ScrollView(.vertical) { course.background(OverlayScrollerStyle()) }
                .frame(height: listMaxHeight)
        } else {
            course
        }
    }

    // Drag to reorder: the lifted row follows the pointer, the others slide 0.24 s.

    private var draggingIndex: Int? { session.entries.firstIndex { $0.id == dragging } }

    private func targetIndex(count: Int) -> Int {
        guard let from = draggingIndex else { return 0 }
        return max(0, min(count - 1, from + Int((dragOffset / Self.rowStep).rounded())))
    }

    private func offset(for index: Int, count: Int) -> CGFloat {
        guard let from = draggingIndex else { return 0 }
        if index == from { return dragOffset }
        let to = targetIndex(count: count)
        if from < to, index > from, index <= to { return -Self.rowStep }
        if from > to, index < from, index >= to { return Self.rowStep }
        return 0
    }

    private func drag(_ row: StackRow, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                dragging = row.id
                dragOffset = value.translation.height
            }
            .onEnded { _ in
                let to = targetIndex(count: count)
                dragging = nil
                dragOffset = 0
                session.move(entryID: row.id, to: to)
            }
    }

    // MARK: The new-copy rail

    /// Two lines: the copy itself, then the keys that move it.
    @ViewBuilder
    private func rail(_ rows: [StackRow]) -> some View {
        if dragging == nil, session.isRailVisible, let row = rows.first(where: { $0.id == session.recentEntryID }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.string("stack.rail.new", language))
                        .font(Tokens.Fonts.label)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                    Text(row.title)
                        .font(row.isCode ? Tokens.Fonts.mono : Tokens.Fonts.body)
                        .foregroundStyle(Tokens.Colors.text)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    railButton("⌥1", "stack.rail.first", to: 0)
                    if session.offersSecondPlace { railButton("⌥2", "stack.rail.second", to: 1) }
                    Spacer(minLength: 0)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Colors.tile)
            .overlay(alignment: .bottomLeading) { CountdownBar(duration: session.railDuration).id(row.id) }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
            .transition(.opacity)
        }
    }

    private func railButton(_ key: String, _ label: String, to index: Int) -> some View {
        Button { session.moveRecent(to: index) } label: {
            HStack(spacing: 6) {
                Keycap(key)
                Text(L10n.string(label, language))
                    .font(Tokens.Fonts.label)
                    .foregroundStyle(Tokens.Colors.text)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 3)
            .padding(.trailing, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(ActionButtonStyle())
    }
}

struct StackRow: Identifiable, Equatable {
    /// The stack entry's id (the same item can be queued twice).
    var id: Int
    var number: Int
    var title: String
    var isCode: Bool
    var source: String?
}

/// One 40 pt row like a history row: keycap number · title · source app, which gives way to the
/// row's actions on hover.
private struct StackRowView: View {
    let row: StackRow
    let isNext: Bool
    let isDragging: Bool
    let isSorting: Bool
    let language: AppLanguage
    let toTop: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Tokens.Metrics.rowRadius, style: .continuous) }
    private var showsActions: Bool { hovering && !isSorting }

    var body: some View {
        HStack(spacing: 12) {
            StackNumberKey(number: row.number, isNext: isNext)
            Text(row.title)
                .font(row.isCode ? Tokens.Fonts.mono : Tokens.Fonts.row)
                .foregroundStyle(Tokens.Colors.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Both are always laid out, so the title never reflows on hover.
            ZStack(alignment: .trailing) {
                Text(row.source ?? "")
                    .font(Tokens.Fonts.label)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(showsActions ? 0 : 1)
                actions
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
            }
            .animation(Tokens.Motion.resolved(.easeOut(duration: 0.15)), value: showsActions)
        }
        .padding(.horizontal, 10)
        .frame(height: Tokens.Metrics.rowHeight)
        .background(fill, in: shape)
        .overlay { if isDragging { shape.strokeBorder(Tokens.Colors.edge, lineWidth: 0.5) } }
        .shadow(color: .black.opacity(isDragging ? 0.3 : 0), radius: 10, y: 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        if isDragging { return Tokens.Colors.surfaceLifted }
        if isNext { return Tokens.Colors.selection }
        return showsActions ? Tokens.Colors.rowHover : .clear
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if !isNext {
                IconButton(symbol: "arrow.up.to.line", size: 12, weight: .regular, label: L10n.string("stack.toTop", language), action: toTop)
            }
            IconButton(symbol: "xmark", size: 10, weight: .semibold, label: L10n.string("stack.remove", language), action: remove)
        }
    }
}

/// A Sıra number on a keycap, as in the panel's ⌘1–9 keys; the next one reads in full text color.
struct StackNumberKey: View {
    let number: Int
    let isNext: Bool

    var body: some View {
        Text("\(number)")
            .font(Tokens.Fonts.keycap)
            .monospacedDigit()
            .foregroundStyle(isNext ? Tokens.Colors.text : Tokens.Colors.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Tokens.Colors.keycapFill, in: RoundedRectangle(cornerRadius: Tokens.Metrics.keycapRadius, style: .continuous))
    }
}

/// 26 pt icon button: secondary glyph, a tile behind it on hover.
private struct IconButton: View {
    let symbol: String
    let size: CGFloat
    let weight: Font.Weight
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(hovering ? Tokens.Colors.text : Tokens.Colors.textSecondary)
                .frame(width: 26, height: 26)
                .background(hovering ? Tokens.Colors.tile : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The rail's 2 pt bar, draining left to right over the rail's lifetime. Drawn from the clock
/// rather than as one long animation: a 7 s animated transaction also caught the window's own
/// resize and slid the whole sheet down while it ran.
private struct CountdownBar: View {
    let duration: Duration
    @State private var start = Date()

    var body: some View {
        // Reduce Motion: the bar stays full.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: Tokens.Motion.reduceMotion())) { context in
            let total = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            let remaining = max(0, 1 - context.date.timeIntervalSince(start) / total)
            Rectangle()
                .fill(Tokens.Colors.textTertiary)
                .frame(height: 2)
                .scaleEffect(x: remaining, y: 1, anchor: .leading)
        }
    }
}

/// Drags its window: the Sıra's header and footer move it anywhere (it never becomes key, so it
/// takes the first click).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
