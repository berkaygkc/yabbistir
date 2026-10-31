import AppKit
import SwiftUI
import YabExtensionKit
import YabExtensions
import YabLocalization

/// Settings → Extensions → Store: search and a category filter over the catalog, rows to tick for installing, the
/// updates waiting, and one consent sheet for everything picked. ↑↓ move through the list, Space ticks, ↵ installs.
struct StoreView: View {
    @Bindable var model: StoreModel
    @FocusState private var listFocused: Bool
    @State private var cursor: String?
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.hasCatalog, model.updateCount > 0 {
                updatesBar
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.hasCatalog {
                Divider()
                footer
            }
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
        .sheet(item: $model.pendingConsent) { consent in
            StoreConsentSheet(consent: consent, language: model.language,
                              onConfirm: { model.confirmConsent() }, onCancel: { model.cancelConsent() })
        }
    }

    private func string(_ key: String) -> String { L10n.string(key, model.language) }

    // MARK: Search, category, refresh

    private var toolbar: some View {
        HStack(spacing: 8) {
            Group {
                StoreSearchField(text: $model.query, prompt: string("extensions.store.search"))
                    .frame(minWidth: 140, maxWidth: .infinity)
                Picker(string("extensions.store.category"), selection: $model.category) {
                    Text(string("extensions.store.category.all")).tag(ExtensionCategory?.none)
                    if !model.categories.isEmpty { Divider() }
                    ForEach(model.categories, id: \.self) { category in
                        Text(model.categoryName(category)).tag(Optional(category))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!model.hasCatalog)
            // The spinner takes the button's place, so nothing moves while the store is checked.
            ZStack {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(string("extensions.store.refreshing"))
                } else {
                    Button(action: model.refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Tokens.Colors.textSecondary)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(string("extensions.store.refresh"))
                    .accessibilityLabel(string("extensions.store.refresh"))
                }
            }
            .frame(width: 24, height: 22)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Updates

    private var updatesBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.updatesTitle)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
            Spacer(minLength: 8)
            Button(string("extensions.store.updateAll")) { model.updateAll() }
                .controlSize(.small)
                .disabled(model.isInstalling)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Tokens.Colors.footerTint)
    }

    // MARK: List and states

    @ViewBuilder private var content: some View {
        if let unavailable = model.unavailable {
            StoreUnavailableView(unavailable: unavailable, tryAgain: string("extensions.store.tryAgain"),
                                 isRefreshing: model.isRefreshing, onTryAgain: model.refresh)
        } else if model.isLoading {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(string("extensions.store.loading"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if let empty = model.emptyMessage {
            Text(empty)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
        } else {
            list
        }
    }

    private var list: some View {
        let rows = model.rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        StoreRowView(row: row, isCursor: listFocused && cursor == row.id, isHovered: hovered == row.id,
                                     installing: string("extensions.store.installing"))
                            .id(row.id)
                            .onHover { inside in
                                if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
                            }
                            .onTapGesture {
                                cursor = row.id
                                listFocused = true
                                if row.isSelectable { model.setSelected(row.id, !row.isSelected) }
                            }
                            .accessibilityAction { if row.isSelectable { model.setSelected(row.id, !row.isSelected) } }
                    }
                }
                // With the rows' own 10 pt, content lines up with the 16 pt gutter of the bars above and below.
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
            .focusable(interactions: .edit)
            .focused($listFocused)
            .focusEffectDisabled()
            .onChange(of: listFocused) { _, focused in
                if focused, cursor.map({ id in !rows.contains { $0.id == id } }) ?? true { cursor = rows.first?.id }
            }
            .onKeyPress(.upArrow) { move(-1, in: rows, proxy) }
            .onKeyPress(.downArrow) { move(1, in: rows, proxy) }
            .onKeyPress(.space) {
                guard let row = rows.first(where: { $0.id == cursor }), row.isSelectable else { return .ignored }
                model.setSelected(row.id, !row.isSelected)
                return .handled
            }
            .onKeyPress(.return) {
                guard model.selectedCount > 0, !model.isInstalling else { return .ignored }
                model.installSelected()
                return .handled
            }
        }
    }

    private func move(_ step: Int, in rows: [StoreModel.Row], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let index = cursor.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        cursor = rows[next].id
        proxy.scrollTo(rows[next].id)
        return .handled
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let notice = model.notice {
                Image(systemName: notice.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(notice.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(model.installTitle) { model.installSelected() }
                .disabled(model.selectedCount == 0 || model.isInstalling)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
    }
}

/// One catalog entry: a tick box when it can be installed, its icon, name and version, what it does, who made it and
/// what it may reach, and its state on the right.
struct StoreRowView: View {
    let row: StoreModel.Row
    let isCursor: Bool
    let isHovered: Bool
    let installing: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            checkbox
                .frame(width: 16, height: 32)
            ExtensionIconTile(icon: row.icon, size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(row.fromVersion.map { "\($0) → \(row.version)" } ?? row.version)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                    Spacer(minLength: 8)
                    trailing
                }
                Text(row.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.hosts.joined(separator: ", "))
                if let failure = row.failure {
                    Label {
                        Text(failure).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Metrics.rowRadius, style: .continuous)
                .fill(isCursor ? Tokens.Colors.selection : isHovered ? Tokens.Colors.rowHover : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isSelectable ? [.isToggle] : [])
        .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
    }

    private var meta: String {
        [row.author, row.permissionSummary].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The tick box draws the row's state; the whole row takes the click. One that cannot be installed shows a dimmed
    /// box when it never could (a newer yabbistir is needed), and nothing when it is already here.
    @ViewBuilder private var checkbox: some View {
        if row.isSelectable || isIncompatible {
            Toggle("", isOn: .constant(row.isSelected))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!row.isSelectable)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }

    private var isIncompatible: Bool {
        if case .incompatible = row.status { return true }
        return false
    }

    @ViewBuilder private var trailing: some View {
        if row.isInstalling {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(installing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if let label = row.statusLabel {
            TagChip(text: label)
                .fixedSize()
        }
    }
}

/// No catalog to show: what happened, in one calm line and a hint, and a way to try again.
struct StoreUnavailableView: View {
    let unavailable: StoreModel.Unavailable
    let tryAgain: String
    let isRefreshing: Bool
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: unavailable.symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(unavailable.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(unavailable.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Button(tryAgain, action: onTryAgain)
                .controlSize(.small)
                .disabled(isRefreshing)
                .padding(.top, 4)
        }
        .frame(maxWidth: 360)
        .padding(24)
    }
}

/// The one sheet before anything is downloaded: each extension with what it asks for, or for updates only what is new.
/// ↵ confirms, ⎋ cancels.
struct StoreConsentSheet: View {
    let consent: StoreModel.Consent
    let language: AppLanguage
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private func string(_ key: String, _ arguments: CVarArg...) -> String {
        arguments.isEmpty ? L10n.string(key, language) : String(format: L10n.string(key, language), locale: language.locale, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if consent.items.count > 3 {
                ScrollView { blocks.padding(.trailing, 8) }
                    .frame(height: 340)
            } else {
                blocks
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(string("extensions.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 440)
        .environment(\.locale, language.locale)
        .interactiveDismissDisabled()
    }

    private var title: String {
        let count = consent.items.count + consent.quietUpdates.count
        let only = (consent.items + consent.quietUpdates).first?.name ?? ""
        return switch consent.kind {
        case .install: count == 1 ? string("extensions.store.consent.install.one", only) : string("extensions.store.consent.install.many", "\(count)")
        case .update: count == 1 ? string("extensions.store.consent.update.one", only) : string("extensions.store.consent.update.many", "\(count)")
        }
    }

    private var confirm: String {
        switch consent.kind {
        case .install: consent.items.allSatisfy(\.sentences.isEmpty) ? string("extensions.store.install") : string("extensions.consent.install")
        case .update: string("extensions.store.consent.allowUpdate")
        }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: 14) {
            if consent.kind == .update {
                Text(string("extensions.store.consent.newPermissions"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, -4)
            }
            ForEach(consent.items) { item in block(item) }
            if !consent.quietUpdates.isEmpty {
                Text(string("extensions.store.consent.alsoUpdating", consent.quietUpdates.map(\.name).joined(separator: ", ")))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func block(_ item: StoreModel.Consent.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ExtensionIconTile(icon: item.icon, size: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name).font(.system(size: 13, weight: .semibold))
                    Text(item.fromVersion.map { "\($0) → \(item.version)" } ?? item.version)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if item.sentences.isEmpty {
                    Text(string("extensions.store.consent.nothing"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.sentences, id: \.self) { sentence in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                Text(sentence).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 13))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The native search field: magnifier, placeholder and clear button. The text follows each keystroke.
struct StoreSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt {
            field.placeholderString = prompt
            field.setAccessibilityLabel(prompt)
        }
        field.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor final class Coordinator: NSObject {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        @objc func changed(_ sender: NSSearchField) { text.wrappedValue = sender.stringValue }
    }
}
