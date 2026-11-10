import SwiftUI
import YabCore

/// One column: a 32 pt header (category dot, or a source's key, and name) over its own scrolling list. The focused
/// column's selection is the sliding grey fill; other columns keep theirs as a hairline ring.
struct ColumnView: View {
    let column: PanelColumn
    let isFocused: Bool
    @Bindable var model: PanelViewModel
    var snapshot = false
    let onPaste: (Int64) -> Void
    @Namespace private var selection
    /// The row the pointer rests on and its pending hover-preview timer.
    @State private var hoverIntent: (row: Int64, task: Task<Void, Never>)?

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if column.sourceKey != nil {
                // An extension fills the column: its mark, never a hue.
                SourceMark(size: 10)
                    .foregroundStyle(Tokens.Colors.textSecondary)
            } else if let color = column.color {
                Circle()
                    .fill(Tokens.Colors.category(color))
                    .frame(width: 8, height: 8)
                    .opacity(isFocused ? 1 : 0.6)
                    .saturation(isFocused ? 1 : 0.55)
            }
            Text(column.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Tokens.Fonts.columnHeader)
        .foregroundStyle(isFocused ? Tokens.Colors.text : Tokens.Colors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .frame(height: Tokens.Metrics.columnHeaderHeight)
    }

    @ViewBuilder private var list: some View {
        if snapshot {
            Color.clear.overlay(alignment: .top) { rows }.clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    rows.background(OverlayScrollerStyle())
                }
                .scrollIndicators(.automatic)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.015),
                                             .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: model.scrollRequest) { _, request in
                    guard let request, request.column == column.id else { return }
                    withAnimation(Tokens.Motion.resolved(Tokens.Motion.ease(0.2))) { proxy.scrollTo(request.id) }
                }
            }
        }
    }

    private var selectedID: Int64? { model.selectedID(in: column.id) }

    /// ⌘ held: the focused column's first nine rows show 1–9 keycaps in the icon slot (not while the
    /// ⇧ panel has the keyboard: ⌘1–9 do nothing there, and held ⌘ turns its footer instead).
    private func indexKey(for row: RowModel) -> Int? {
        guard isFocused, model.showsIndexKeys, model.layer != .transforms, let position = column.rows.firstIndex(where: { $0.id == row.id }), position < 9 else { return nil }
        return position + 1
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(column.sections) { section in
                if !section.title.isEmpty {
                    Text(section.title)
                        .font(Tokens.Fonts.section)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .padding(EdgeInsets(top: 10, leading: 10, bottom: 5, trailing: 10))
                }
                ForEach(section.rows) { row in
                    rowView(row)
                        .background { selectionMark(for: row) }
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: SelectedRowFrameKey.self,
                                                       value: isFocused && row.id == selectedID ? proxy.frame(in: .global) : nil)
                            }
                        }
                        .id(row.id)
                        .onHover { inside in
                            // Only this row's own exit cancels its timer: the next row's enter can
                            // arrive before this row's exit.
                            guard inside else {
                                if hoverIntent?.row == row.id { hoverIntent?.task.cancel(); hoverIntent = nil }
                                return
                            }
                            // A row that ↑/↓ scrolled under a resting pointer keeps the keyboard's selection.
                            guard model.acceptsHover() else { return }
                            hoverIntent?.task.cancel()
                            model.select(row.id, in: column.id)
                            // Resting on a row for ~380 ms opens the hover preview.
                            hoverIntent = (row.id, Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(380))
                                if !Task.isCancelled { model.hoverIntent(row.id) }
                            })
                        }
                        .onTapGesture(count: 2) {
                            model.select(row.id, in: column.id)
                            onPaste(row.id)
                        }
                        .onTapGesture { model.select(row.id, in: column.id) }
                }
            }
            if let message = column.emptyMessage {
                Text(message)
                    .font(Tokens.Fonts.body)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .padding(.horizontal, 12)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 18, trailing: 8))
        .animation(Tokens.Motion.resolved(Tokens.Motion.selectionSlide), value: selectedID)
    }

    @ViewBuilder private func rowView(_ row: RowModel) -> some View {
        if let command = row.command {
            CommandRowView(command: command, indexKey: indexKey(for: row))
        } else if case .entry(_, let entry)? = row.source {
            SourceRowView(row: row, subtitle: entry.subtitle, query: model.query, indexKey: indexKey(for: row))
        } else if case .locked(_, let message, let command)? = row.source {
            // The column's only row, standing in for an empty text: no ⌘1–9 keycap.
            LockedSourceRowView(message: message, command: command, language: model.language)
        } else {
            HistoryRowView(row: row, query: model.query,
                           thumbnail: row.kind == .image ? model.thumbnails.thumbnail(for: row.itemID) : nil,
                           indexKey: indexKey(for: row))
        }
    }

    // Never under the pointer: mid-slide, the highlight sits over a neighbour row and would
    // steal its hover, flipping the selection back and forth.
    @ViewBuilder private func selectionMark(for row: RowModel) -> some View {
        if row.id == selectedID {
            if isFocused {
                RoundedRectangle(cornerRadius: Tokens.Metrics.rowRadius, style: .continuous)
                    .fill(Tokens.Colors.selection)
                    .matchedGeometryEffect(id: "selection", in: selection)
                    .allowsHitTesting(false)
            } else {
                RoundedRectangle(cornerRadius: Tokens.Metrics.rowRadius, style: .continuous)
                    .strokeBorder(Tokens.Colors.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
