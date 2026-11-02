import Foundation
import Observation
import SwiftUI
import YabCore
import YabExtensions
import YabLocalization

/// The category editor (⌘E): reorder, recolor, rename, set visibility, delete. Every change
/// goes through the Library, so the panel behind it updates live. A source's category is its extension's to name, fill
/// and remove: only its visibility and place are the person's.
@MainActor @Observable
public final class CategoryEditorModel {
    public struct Row: Identifiable, Equatable {
        public var category: ClipCategory
        /// Its items; a source's category counts the rows its list holds now, nil while it has none at hand (locked,
        /// not listed yet).
        public var count: Int?
        public var id: Int64 { category.id ?? -1 }
        /// An extension's source fills it: no colour, name field or delete, only visibility and order.
        public var isSource: Bool { category.isSource }
    }

    public private(set) var rows: [Row] = []
    /// The row the keyboard works on: ↑/↓ move it, ⇥ flips its visibility, typing edits its name.
    public private(set) var selectedID: Int64?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let languageStore: LanguageStore
    /// Where a source's category counts its rows.
    @ObservationIgnored private let sources: SourceProviding?

    public init(library: Library, language: LanguageStore, sources: SourceProviding? = nil) {
        self.library = library
        self.languageStore = language
        self.sources = sources
        reload()
    }

    public var language: AppLanguage { languageStore.language }

    public func reload() {
        let previous = rows.firstIndex { $0.id == selectedID } ?? 0
        let counts = (try? library.store.itemCounts()) ?? [:]
        rows = ((try? library.store.categories()) ?? []).map { category in
            Row(category: category, count: category.source.map(sourceCount) ?? counts[category.id ?? -1] ?? 0)
        }
        if !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.isEmpty ? nil : rows[min(previous, rows.count - 1)].id
        }
    }

    public func select(_ id: Int64) {
        if rows.contains(where: { $0.id == id }) { selectedID = id }
    }

    public func moveSelection(by delta: Int) {
        guard let current = rows.firstIndex(where: { $0.id == selectedID }) else { return }
        selectedID = rows[max(0, min(rows.count - 1, current + delta))].id
    }

    /// ⇥: Always ↔ On select for the selected category.
    public func toggleSelectedVisibility() {
        guard let row = rows.first(where: { $0.id == selectedID }) else { return }
        setVisibility(row.id, row.category.visibility == .always ? .onSelect : .always)
    }

    /// False (and the old name stays) for a blank name, one another category already has, or a source's category.
    @discardableResult
    public func rename(_ id: Int64, to name: String) -> Bool {
        guard var category = rows.first(where: { $0.id == id })?.category, !category.isSource else { return false }
        category.name = name
        return save(category)
    }

    /// False for a source's category, which shows its key, not a colour.
    @discardableResult
    public func setColor(_ id: Int64, _ color: CategoryColor) -> Bool {
        guard var category = rows.first(where: { $0.id == id })?.category, !category.isSource else { return false }
        category.color = color
        return save(category)
    }

    public func setVisibility(_ id: Int64, _ visibility: CategoryVisibility) {
        guard var category = rows.first(where: { $0.id == id })?.category else { return }
        category.visibility = visibility
        save(category)
    }

    public func move(from: Int, to: Int) {
        guard rows.indices.contains(from), from != to else { return }
        try? library.moveCategory(id: rows[from].id, to: to)
        reload()
    }

    /// False for a source's category: it leaves when its extension does.
    @discardableResult
    public func delete(_ id: Int64) -> Bool {
        guard let row = rows.first(where: { $0.id == id }), !row.isSource else { return false }
        defer { reload() }
        return (try? library.deleteCategory(id: id)) != nil
    }

    /// "New category", then "New category 2", "New category 3"…: on select, next unused color,
    /// selected.
    public func addCategory() {
        let base = L10n.string("editor.new", language)
        let taken = Set(rows.map { SearchNormalizer.normalize($0.category.name) })
        var name = base
        var number = 2
        while taken.contains(SearchNormalizer.normalize(name)) {
            name = "\(base) \(number)"
            number += 1
        }
        let created = try? library.createCategory(name: name)
        reload()
        // ⌘N / the button: the new row takes the keyboard, its name ready to type over.
        if let id = created?.id { selectedID = id }
    }

    /// The rows a source lists now; nil while it has none at hand.
    private func sourceCount(_ key: String) -> Int? {
        guard case .rows(let rows)? = sources?.state(of: key) else { return nil }
        return rows.count
    }

    @discardableResult
    private func save(_ category: ClipCategory) -> Bool {
        defer { reload() }
        do {
            try library.updateCategory(category)
            return true
        } catch {
            return false
        }
    }
}

/// 440 pt glass sheet: title and description, 46 pt rows with a
/// grip, color well, inline name, item count, Always / On select segments and delete. A source's row has its key in
/// the well's place, its name as fixed text and an empty slot where delete would be, so the columns stay in line.
public struct CategoryEditorView: View {
    @Bindable var model: CategoryEditorModel
    let onClose: () -> Void
    @State private var dragging: Int64?
    @State private var dragOffset: CGFloat = 0
    @State private var paletteFor: Int64?
    /// The name field with keyboard focus follows the selected row.
    @FocusState private var focusedRow: Int64?

    private static let rowStep: CGFloat = 48

    public init(model: CategoryEditorModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 2) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    EditorRow(model: model, row: row, isSelected: row.id == model.selectedID,
                              paletteFor: $paletteFor, focus: $focusedRow)
                        .offset(y: offset(for: index))
                        .zIndex(dragging == row.id ? 1 : 0)
                        .shadow(color: .black.opacity(dragging == row.id ? 0.45 : 0), radius: 15, y: 12)
                        .scaleEffect(dragging == row.id ? 1.02 : 1)
                        .gesture(drag(for: index, row: row))
                }
            }
            .padding(.horizontal, 10)
            .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.24)), value: dragging == nil ? 0 : targetIndex)
            footer
            hints
        }
        .onAppear { focusedRow = model.selectedID }
        .onChange(of: model.selectedID) { _, id in focusedRow = id }
        .onChange(of: focusedRow) { _, id in if let id { model.select(id) } }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelBackground(material: PanelMaterial.current, cornerRadius: 20))
        .environment(\.locale, model.language.locale)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("editor.title", model.language)).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.text)
                Text(L10n.string("editor.subtitle", model.language)).font(Tokens.Fonts.label)
                    .foregroundStyle(Tokens.Colors.textSecondary)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Tokens.Colors.keycapFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("editor.close", model.language))
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 14, trailing: 16))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: model.addCategory) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text(L10n.string("editor.new", model.language)).font(Tokens.Fonts.labelStrong).lineLimit(1).fixedSize()
                }
                .foregroundStyle(Tokens.Colors.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Tokens.Colors.tile, in: RoundedRectangle(cornerRadius: Tokens.Metrics.controlRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            Text(L10n.string("editor.note", model.language)).font(Tokens.Fonts.label)
                .foregroundStyle(Tokens.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20))
        .overlay(alignment: .top) { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5).padding(.top, 6) }
    }

    /// The keys that drive the editor, like the preview's hint bar.
    private var hints: some View {
        HStack(spacing: 14) {
            hint(["↑", "↓"], "editor.hint.select")
            hint(["⇥"], "editor.hint.visibility")
            hint(["⌘", "N"], "editor.hint.new")
            hint(["esc"], "editor.close")
            Spacer(minLength: 0)
        }
        .font(Tokens.Fonts.label)
        .foregroundStyle(Tokens.Colors.textSecondary)
        .padding(EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20))
        .overlay(alignment: .top) { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5) }
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap($0) } }
            Text(L10n.string(label, model.language)).lineLimit(1).fixedSize()
        }
    }

    // MARK: Drag to reorder (siblings slide 0.24 s, the lifted row follows the pointer)

    private var draggingIndex: Int? { model.rows.firstIndex { $0.id == dragging } }

    private var targetIndex: Int {
        guard let from = draggingIndex else { return 0 }
        return max(0, min(model.rows.count - 1, from + Int((dragOffset / Self.rowStep).rounded())))
    }

    private func offset(for index: Int) -> CGFloat {
        guard let from = draggingIndex else { return 0 }
        if index == from { return dragOffset }
        let to = targetIndex
        if from < to, index > from, index <= to { return -Self.rowStep }
        if from > to, index < from, index >= to { return Self.rowStep }
        return 0
    }

    private func drag(for index: Int, row: CategoryEditorModel.Row) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                dragging = row.id
                dragOffset = value.translation.height
            }
            .onEnded { _ in
                let to = targetIndex
                dragging = nil
                dragOffset = 0
                model.move(from: index, to: to)
            }
    }
}

private struct EditorRow: View {
    @Bindable var model: CategoryEditorModel
    let row: CategoryEditorModel.Row
    let isSelected: Bool
    @Binding var paletteFor: Int64?
    var focus: FocusState<Int64?>.Binding
    @State private var name = ""
    @State private var hoveringDelete = false

    private var editing: Bool { focus.wrappedValue == row.id }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 12)).foregroundStyle(Tokens.Colors.textTertiary)
            if row.isSource {
                SourceMark(size: 13).foregroundStyle(Tokens.Colors.textSecondary).frame(width: 20, height: 20)
                // The extension names it: fixed text, set where the field's text sits.
                Text(row.category.name)
                    .font(Tokens.Fonts.body)
                    .foregroundStyle(Tokens.Colors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 26)
            } else {
                colorWell
                nameField
            }
            Text(row.count.map { "\($0)" } ?? "").font(Tokens.Fonts.label).monospacedDigit().foregroundStyle(Tokens.Colors.textSecondary)
                .fixedSize()
            segments
            if row.isSource {
                Color.clear.frame(width: 26, height: 26)
            } else {
                Button { model.delete(row.id) } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                        .foregroundStyle(hoveringDelete ? Tokens.Colors.danger : Tokens.Colors.textSecondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .onHover { hoveringDelete = $0 }
                .accessibilityLabel(L10n.string("actions.delete", model.language))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(isSelected ? Tokens.Colors.selection : Tokens.Colors.tile.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.select(row.id) }
        .onAppear { name = row.category.name }
        .onChange(of: row.category.name) { _, new in if !editing { name = new } }
    }

    private var nameField: some View {
        TextField("", text: $name)
            .textFieldStyle(.plain)
            .font(Tokens.Fonts.body)
            .foregroundStyle(Tokens.Colors.text)
            .focused(focus, equals: row.id)
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(editing ? Tokens.Colors.tile : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(editing ? Tokens.Colors.accentSoft : .clear, lineWidth: 2))
            .onSubmit(commit)
            .onChange(of: focus.wrappedValue) { old, new in if old == row.id, new != row.id { commit() } }
    }

    private func commit() {
        guard name != row.category.name else { return }
        if !model.rename(row.id, to: name) { name = row.category.name }
    }

    private var colorWell: some View {
        Button { paletteFor = paletteFor == row.id ? nil : row.id } label: {
            Circle().fill(Tokens.Colors.category(row.category.color))
                .frame(width: 14, height: 14)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Tokens.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { paletteFor == row.id }, set: { if !$0 { paletteFor = nil } }), arrowEdge: .bottom) {
            HStack(spacing: 8) {
                ForEach(CategoryColor.allCases, id: \.self) { color in
                    Button {
                        model.setColor(row.id, color)
                        paletteFor = nil
                    } label: {
                        Circle().fill(Tokens.Colors.category(color)).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Tokens.Colors.text, lineWidth: color == row.category.color ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("category.color.\(color.rawValue)", model.language))
                }
            }
            .padding(12)
        }
    }

    /// Labels keep their full width in every language; the name field gives way instead.
    private var segments: some View {
        HStack(spacing: 0) {
            segment(.always, "editor.always")
            segment(.onSelect, "editor.onSelect")
        }
        .padding(2)
        .background(Tokens.Colors.tile, in: RoundedRectangle(cornerRadius: Tokens.Metrics.controlRadius, style: .continuous))
        .fixedSize()
        .layoutPriority(1)
    }

    private func segment(_ visibility: CategoryVisibility, _ key: String) -> some View {
        let on = row.category.visibility == visibility
        return Button { model.setVisibility(row.id, visibility) } label: {
            Text(L10n.string(key, model.language)).font(Tokens.Fonts.label.weight(on ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? Tokens.Colors.text : Tokens.Colors.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Tokens.Colors.surfaceSolid)
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
