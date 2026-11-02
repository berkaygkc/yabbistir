import AppKit
import SwiftUI
import YabCore
import YabLocalization

/// Which parts of a category row the person may change.
public enum CategoryRowRules {
    /// False for a source's category: its extension names, fills and removes it; only its visibility and place are
    /// the person's.
    public static func canEdit(_ row: CategoryEditorModel.Row) -> Bool { !row.isSource }
}

/// Settings → Categories: rename, color, order, visibility and delete, on the editor's model.
public struct CategoriesSettingsView: View {
    @Bindable var model: CategoryEditorModel
    let presence: SettingsPresence
    @State private var deleting: CategoryEditorModel.Row?

    public init(model: CategoryEditorModel, presence: SettingsPresence) {
        self.model = model
        self.presence = presence
    }

    private var lang: AppLanguage { model.language }

    public var body: some View {
        Form {
            Section {
                List {
                    ForEach(model.rows) { row in
                        CategorySettingsRow(model: model, row: row) { deleting = row }
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        model.move(from: from, to: destination > from ? destination - 1 : destination)
                    }
                }
                .frame(minHeight: CGFloat(max(model.rows.count, 3)) * 36)
                Button { model.addCategory() } label: {
                    Label(L10n.string("settings.categories.add", lang), systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } footer: {
                if model.rows.contains(where: { !CategoryRowRules.canEdit($0) }) {
                    Text(L10n.string("settings.categories.source.note", lang)).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reload() }
        // The panel's editor may have changed categories meanwhile: rows are read fresh whenever Settings comes forward.
        .onChange(of: presence.forwardCount) { model.reload() }
        .navigationTitle(L10n.string("settings.section.categories", lang))
        .confirmationDialog(
            L10n.string("settings.categories.delete.title", lang, deleting?.category.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { row in
            Button(L10n.string("settings.categories.delete.confirm", lang), role: .destructive) {
                model.delete(row.id)
                deleting = nil
            }
            Button(L10n.string("settings.cancel", lang), role: .cancel) { deleting = nil }
        } message: { _ in
            Text(L10n.string("settings.categories.delete.message", lang))
        }
    }
}

private struct CategorySettingsRow: View {
    @Bindable var model: CategoryEditorModel
    let row: CategoryEditorModel.Row
    let onDelete: () -> Void
    @State private var editing = false
    @State private var name = ""
    @FocusState private var focused: Bool

    private var lang: AppLanguage { model.language }
    private var editable: Bool { CategoryRowRules.canEdit(row) }

    var body: some View {
        HStack(spacing: 10) {
            if editable {
                colorMenu
                nameView
            } else {
                SourceMark(size: 13).foregroundStyle(.secondary).frame(width: 20, height: 20)
                Text(row.category.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(row.count.map { "\($0)" } ?? "").monospacedDigit().foregroundStyle(.secondary)
            Picker(L10n.string("editor.hint.visibility", lang), selection: Binding(
                get: { row.category.visibility }, set: { model.setVisibility(row.id, $0) })) {
                Text(L10n.string("settings.categories.visibility.always", lang)).tag(CategoryVisibility.always)
                Text(L10n.string("settings.categories.visibility.onDemand", lang)).tag(CategoryVisibility.onSelect)
            }
            .labelsHidden()
            .fixedSize()
            if editable {
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.string("actions.delete", lang))
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
        .padding(.vertical, 2)
    }

    private var colorMenu: some View {
        Menu {
            ForEach(CategoryColor.allCases, id: \.self) { color in
                Button { model.setColor(row.id, color) } label: {
                    Label(L10n.string("category.color.\(color.rawValue)", lang),
                          systemImage: color == row.category.color ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(Tokens.Colors.category(color))
                }
            }
        } label: {
            Circle().fill(Tokens.Colors.category(row.category.color))
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Tokens.Colors.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.string("kind.color", lang))
        .accessibilityValue(L10n.string("category.color.\(row.category.color.rawValue)", lang))
    }

    @ViewBuilder private var nameView: some View {
        if editing {
            TextField("", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
                .onExitCommand { editing = false }
                .onAppear { focused = true }
        } else {
            Text(row.category.name).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    name = row.category.name
                    editing = true
                }
        }
    }

    /// A refused name (blank, taken) leaves the old one showing.
    private func commit() {
        guard editing else { return }
        editing = false
        if name != row.category.name { _ = model.rename(row.id, to: name) }
    }
}
