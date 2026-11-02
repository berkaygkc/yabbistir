import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import YabExtensionKit
import YabExtensions
import YabLocalization

/// The ⇧ panel (344 pt): the item on top, its ⇧↵ default first ("Varsayılan"), "Paste as plain
/// text" for rich text ("yabbistir"), the paste target's own actions ("Finder’a"), then its
/// transforms grouped by extension with each one's output on the right, the highlighted one's
/// result below, then the keys; ⌘K opens its own menu over the lower right. On a source's row it
/// lists that row's actions instead (`sourceList`).
public struct TransformPanelView: View {
    @Bindable var model: PanelViewModel
    let onAction: (PanelAction) -> Void

    public init(model: PanelViewModel, onAction: @escaping (PanelAction) -> Void) {
        self.model = model
        self.onAction = onAction
    }

    public var body: some View {
        if let source = model.transformSource {
            sourceList(source)
        } else {
            transforms
        }
    }

    @ViewBuilder private var transforms: some View {
        let rows = model.transformRows
        let sections = model.transformSections
        VStack(alignment: .leading, spacing: 0) {
            header(count: rows.count)
            if !model.transformQuery.isEmpty { queryLine }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if let section = sections.first(where: { $0.rows.lowerBound == index }) { sectionHeader(section) }
                MenuRow(title: title(of: row), isHighlighted: index == model.menuSelection, keepsTitle: true) {
                    EmptyView()
                } trailing: {
                    if let hint = hint(for: row), !hint.isEmpty {
                        Text(hint)
                            .font(Self.isPlain(row) ? .system(size: 11.5) : .system(size: 11.3, design: .monospaced))
                            .foregroundStyle(Tokens.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 168, alignment: .trailing)
                            .padding(.leading, 4)
                    }
                }
                // While ⌘K is open the highlighted row is the one it acts on, so the pointer leaves it be.
                .onHover { if $0, !model.transformMenuOpen { model.highlightMenuRow(index) } }
                .onTapGesture {
                    // A click beside the open menu closes it, as a click outside any menu does.
                    guard !model.transformMenuOpen else { _ = model.handle(.toggleActions); return }
                    model.highlightMenuRow(index)
                    if let action = model.handle(.confirm(plain: false)) { onAction(action) }
                }
            }
            if rows.isEmpty {
                Text(L10n.string("transforms.empty", model.language, model.transformQuery))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 10)
            } else if rows.indices.contains(model.menuSelection) {
                result(rows[model.menuSelection])
            }
            footer
        }
        .padding(6)
        .frame(width: 344)
        .background(PanelBackground(material: PanelMaterial.current, cornerRadius: 14))
        .environment(\.locale, model.language.locale)
    }

    // MARK: A source's row

    /// A source row's ⇧ (a vault's entry): its tile, title and username on top; its actions, each with its key (↵ runs
    /// the highlighted one, ⇧↵ and ⌘C work as on the row); then "↵ Yapıştır" ("↵ Kopyala" on the copy row) and "← Geri".
    /// No outputs and no result: a password has nothing to show, and the username is already on top.
    private func sourceList(_ source: SourceSubject) -> some View {
        let items = model.sourceListItems
        return VStack(alignment: .leading, spacing: 0) {
            header(title: source.row.title, subtitle: source.row.subtitle) {
                InitialTile(title: source.row.title).frame(width: 22, height: 22)
            }
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                MenuRow(title: model.actionLabel(item), isHighlighted: index == model.menuSelection, keepsTitle: true) {
                    EmptyView()
                } trailing: {
                    HStack(spacing: 3) { ForEach(ActionMenuView.keys(item, shiftReturn: nil), id: \.self) { Keycap($0) } }
                }
                .onHover { if $0 { model.highlightMenuRow(index) } }
                .onTapGesture {
                    model.highlightMenuRow(index)
                    if let action = model.handle(.confirm(plain: false)) { onAction(action) }
                }
            }
            HStack(spacing: 14) {
                hint(["↵"], model.sourceListConfirmLabel)
                Spacer(minLength: 0)
                hint(["←"], L10n.string("transforms.back", model.language))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Tokens.Colors.textSecondary)
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 3, trailing: 10))
            .overlay(alignment: .top) { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5) }
            .padding(.top, 4)
        }
        .padding(6)
        .frame(width: 344)
        .background(PanelBackground(material: PanelMaterial.current, cornerRadius: 14))
        .environment(\.locale, model.language.locale)
    }

    // MARK: Parts

    private func header(count: Int) -> some View {
        header(title: model.transformSubjectRow?.title ?? "", subtitle: subtitle(count: count)) {
            if let row = model.transformSubjectRow {
                RowIcon(row: row, thumbnail: row.kind == .image ? model.thumbnails.thumbnail(for: row.itemID) : nil)
                    .frame(width: 22, height: 22)
            }
        }
    }

    /// The subject on top: its icon, its title and a line under it, over a hairline.
    private func header<Icon: View>(title: String, subtitle: String?, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 10) {
            icon()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 9, trailing: 8))
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5) }
        .padding(.bottom, 2)
    }

    private func subtitle(count: Int) -> String {
        let transforms = L10n.string("transforms.count", model.language, NumberFormatting.count(count, language: model.language))
        return [model.transformSubjectApp, transforms].compactMap { $0 }.joined(separator: " · ")
    }

    private var queryLine: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Tokens.Colors.textSecondary)
            HStack(spacing: 0) {
                Text(model.transformQuery).font(.system(size: 12.5)).foregroundStyle(Tokens.Colors.text)
                BlinkingCaret().scaleEffect(0.7, anchor: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func sectionHeader(_ section: TransformSection) -> some View {
        HStack(spacing: 7) {
            if let icon = Self.icon(section.mark) {
                CommandIcon(icon: icon)
                    .scaleEffect(0.85)
                    .frame(width: 14, height: 14)
            }
            Text(section.title)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Tokens.Colors.textSecondary)
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 4, trailing: 10))
    }

    /// The highlighted row's output: a swatch beside a color's value, a thumbnail beside an
    /// image's format, a file's tile beside where it goes, otherwise up to three lines of text
    /// (for "Paste as plain text", the item's own).
    @ViewBuilder private func result(_ row: TransformRow) -> some View {
        HStack(spacing: 11) {
            switch row {
            case .plainText:
                Text(model.transformPlainText ?? "")
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(Tokens.Colors.text)
                    .lineLimit(3)
                    .truncationMode(.tail)
            case .command(let command) where Self.makesFiles(command):
                fileResult(command)
            case .command(let command):
                output(command)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 11, leading: 10, bottom: 6, trailing: 10))
        .frame(minHeight: 54)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5) }
        .padding(.top, 6)
    }

    /// A file is made only when the action is used, so its name is not known yet: the action's icon
    /// on a tile, what it makes (the variant's subtitle, else its title), and where the file goes.
    @ViewBuilder private func fileResult(_ command: ExtensionCommand) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Tokens.Colors.tile)
            .frame(width: 30, height: 30)
            .overlay { CommandIcon(icon: command.icon) }
        VStack(alignment: .leading, spacing: 1) {
            Text(command.subtitle ?? command.title)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.Colors.text)
                .lineLimit(2)
            Text(model.transformFileDestination)
                .font(.system(size: 11))
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
        }
    }

    /// What the transform gave, once it ran; a spinner while its hint is on its way, else a note
    /// that it runs when used.
    @ViewBuilder private func output(_ command: ExtensionCommand) -> some View {
        switch model.transformOutput(command) {
        case .image(let data, let uti, let width, let height)?:
            if let image = Self.thumbnail(data) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 66, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.format(uti)).font(.system(size: 12.5)).foregroundStyle(Tokens.Colors.text)
                Text(verbatim: "\(width)×\(height)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Tokens.Colors.textSecondary)
            }
        case let output?:
            if let hex = model.transformSubjectRow?.colorHex, let color = Color(hex: hex) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 30, height: 30)
            }
            Text(Self.text(of: output))
                .font(Self.isPlain(command) ? .system(size: 12.5) : .system(size: 11.8, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(Tokens.Colors.text)
                .lineLimit(3)
                .truncationMode(.tail)
        case nil where model.transformRunsAhead(command):
            ProgressView().controlSize(.small)
        case nil:
            Text(L10n.string("preview.command.runsWhenUsed", model.language))
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.Colors.textSecondary)
        }
    }

    /// "↵ Yapıştır · ⌘C Kopyala", or a job's verb ("↵ İndir · ⌘C İndir ve kopyala"); "← Geri" on the
    /// right, "⌘K Eylemler" while ⌘ is held. With a verb too long for "⌘K Eylemler" ("İndir ve
    /// kopyala"), "← Geri" stays put; too long for "← Geri" too ("Download and copy"), the right one
    /// is left out (← and Esc still close the panel, ⌘K still opens its menu), and the panel keeps
    /// its width. ⌘K's menu stands on the footer's hairline.
    private var footer: some View {
        let labels = model.transformKeyLabels
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                hint(["↵"], labels.confirm)
                hint(["⌘", "C"], labels.copy)
                Spacer(minLength: 0)
                backOrActions
            }
            HStack(spacing: 14) {
                hint(["↵"], labels.confirm)
                hint(["⌘", "C"], labels.copy)
                Spacer(minLength: 0)
                hint(["←"], L10n.string("transforms.back", model.language))
            }
            HStack(spacing: 14) {
                hint(["↵"], labels.confirm)
                hint(["⌘", "C"], labels.copy, fixed: false)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Tokens.Colors.textSecondary)
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 3, trailing: 10))
        .overlay(alignment: .top) { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5) }
        .overlay(alignment: .topTrailing) {
            // Its foot 4 pt above the hairline, as ⌘K stands 4 pt above the main bar. The guide sits on
            // a container: one inside the `if` is dropped.
            ZStack {
                if model.transformMenuOpen {
                    menu.transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
            .alignmentGuide(.top) { $0[.bottom] + 4 }
        }
        .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.14)), value: model.transformMenuOpen)
        .padding(.top, 4)
    }

    /// "← Geri", or "⌘K Eylemler" while ⌘ is held: the main bar's cross-fade and 5 pt slide.
    private var backOrActions: some View {
        let held = model.showsIndexKeys
        return ZStack(alignment: .trailing) {
            hint(["←"], L10n.string("transforms.back", model.language))
                .opacity(held ? 0 : 1)
                .offset(y: held ? -5 : 0)
            hint(["⌘", "K"], L10n.string("panel.footer.actions", model.language))
                .opacity(held ? 1 : 0)
                .offset(y: held ? 0 : 5)
        }
        .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.18)), value: held)
    }

    /// ⌘K (300 pt, ⌘K's rows): make the highlighted row what ⇧↵ runs for this kind of item, or stop
    /// that; then the row's ↵ and ⌘C in the footer's words; the search line at the foot.
    private var menu: some View {
        let items = model.transformMenuItems
        let isJob = highlightedIsJob
        return MenuSurface(width: 300) {
            if items.isEmpty {
                MenuRow(title: L10n.string("actions.none", model.language)) { EmptyView() } trailing: { EmptyView() }
                    .foregroundStyle(Tokens.Colors.textSecondary)
            }
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if index > 0, Self.isDefaultItem(items[index - 1]) != Self.isDefaultItem(item) { MenuSeparator() }
                MenuRow(title: model.transformMenuLabel(item), isHighlighted: index == model.transformMenuSelection) {
                    Image(systemName: Self.symbol(item, isJob: isJob)).font(.system(size: 13)).frame(width: 16)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                } trailing: {
                    HStack(spacing: 3) { ForEach(Self.keys(item), id: \.self) { Keycap($0) } }
                }
                .onHover { if $0 { model.highlightTransformMenuItem(index) } }
                .onTapGesture { if let action = model.activateTransformMenuItem(index) { onAction(action) } }
            }
            ActionSearchLine(query: model.transformMenuQuery, language: model.language)
        }
        // Its own height, not the footer's it is laid over.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// `fixed: false`: the label may shorten rather than widen the panel (the last resort).
    private func hint(_ keys: [String], _ label: String, fixed: Bool = true) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap($0) } }
            Text(label).lineLimit(1).fixedSize(horizontal: fixed, vertical: fixed)
        }
    }

    // MARK: Values

    /// Whether the highlighted row is a job: ↵ starts it (a download) rather than pasting.
    private var highlightedIsJob: Bool {
        let rows = model.transformRows
        guard rows.indices.contains(model.menuSelection), case .command(let command) = rows[model.menuSelection] else { return false }
        return command.isJob
    }

    /// The default's item is a group of its own, above ↵ and ⌘C.
    static func isDefaultItem(_ item: TransformMenuItem) -> Bool {
        item == .setDefault || item == .clearDefault
    }

    /// To the top for the default, a cross to take it back, then paste (a job's download arrow) and copy.
    static func symbol(_ item: TransformMenuItem, isJob: Bool) -> String {
        switch item {
        case .setDefault: "arrow.up.to.line"
        case .clearDefault: "xmark"
        case .run: isJob ? "arrow.down.to.line" : "doc.on.clipboard"
        case .copy: "doc.on.doc"
        }
    }

    static func keys(_ item: TransformMenuItem) -> [String] {
        switch item {
        case .setDefault, .clearDefault: []
        case .run: ["↵"]
        case .copy: ["⌘", "C"]
        }
    }

    private func title(of row: TransformRow) -> String {
        switch row {
        case .plainText: L10n.string("actions.pastePlain", model.language)
        case .command(let command): command.title
        }
    }

    /// The row's right side: the item's text on one line for "Paste as plain text"; an image's
    /// format and size, otherwise the one-line hint.
    private func hint(for row: TransformRow) -> String? {
        guard case .command(let command) = row else {
            return model.transformPlainText.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        }
        if case .image(_, let uti, let width, let height)? = model.transformOutput(command) {
            return "\(Self.format(uti)) · \(width)×\(height)"
        }
        return model.transformHint(command)
    }

    /// The plain-text row reads as prose.
    static func isPlain(_ row: TransformRow) -> Bool {
        switch row {
        case .plainText: true
        case .command(let command): isPlain(command)
        }
    }

    /// Image outputs, readings of an image (OCR), files and jobs are prose (a format, a description);
    /// everything else reads as code.
    static func isPlain(_ command: ExtensionCommand) -> Bool {
        command.output == .image || makesFiles(command) || command.isJob || command.accepts?.kinds.contains("image") == true
    }

    /// A target section's glyph names the kind of app (no app icons: headers stay grey); "yabbistir"
    /// wears the app's own glyph, "Varsayılan" none.
    static func icon(_ mark: TransformSection.Mark) -> String? {
        switch mark {
        case .icon(let icon): icon
        case .target(.finder): "sf:folder"
        case .target(.terminal): "sf:terminal"
        case .target(.browser): "sf:globe"
        case .target(.editor): "sf:doc.text"
        case .target(.other): "sf:macwindow"
        case .app: "sf:\(StatusRingImage.glyphName)"
        case .pinned: nil
        }
    }

    static func makesFiles(_ command: ExtensionCommand) -> Bool {
        command.output == .file || command.output == .files
    }

    static func text(of result: ExtensionResult) -> String {
        switch result {
        case .text(let text), .html(_, let text), .link(let text, _): text
        case .none(let message): message ?? ""
        case .file(let path): URL(fileURLWithPath: path).lastPathComponent
        case .files(let paths): paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "\n")
        case .image: ""
        }
    }

    static func format(_ uti: String) -> String {
        UTType(uti)?.preferredFilenameExtension?.uppercased() ?? uti
    }

    static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 132]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
