import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import YabExtensionKit
import YabExtensions
import YabLocalization

/// The ⇧ panel (344 pt): the item on top, the paste target's own actions
/// first ("Finder’a"), then its transforms grouped by extension with each one's output on the
/// right, the highlighted one's result below, then the keys.
public struct TransformPanelView: View {
    @Bindable var model: PanelViewModel
    let onAction: (PanelAction) -> Void

    public init(model: PanelViewModel, onAction: @escaping (PanelAction) -> Void) {
        self.model = model
        self.onAction = onAction
    }

    public var body: some View {
        let commands = model.transformCommands
        let sections = model.transformSections
        VStack(alignment: .leading, spacing: 0) {
            header(count: commands.count)
            if !model.transformQuery.isEmpty { queryLine }
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                if let section = sections.first(where: { $0.rows.lowerBound == index }) { sectionHeader(section) }
                MenuRow(title: command.title, isHighlighted: index == model.menuSelection) {
                    EmptyView()
                } trailing: {
                    if let hint = hint(for: command), !hint.isEmpty {
                        Text(hint)
                            .font(Self.isPlain(command) ? .system(size: 11.5) : .system(size: 11.3, design: .monospaced))
                            .foregroundStyle(Tokens.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 168, alignment: .trailing)
                            .padding(.leading, 4)
                    }
                }
                .onHover { if $0 { model.highlightMenuRow(index) } }
                .onTapGesture {
                    model.highlightMenuRow(index)
                    if let action = model.handle(.confirm(plain: false)) { onAction(action) }
                }
            }
            if commands.isEmpty {
                Text(L10n.string("transforms.empty", model.language, model.transformQuery))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 10)
            } else if commands.indices.contains(model.menuSelection) {
                result(commands[model.menuSelection])
            }
            footer
        }
        .padding(6)
        .frame(width: 344)
        .background(PanelBackground(material: PanelMaterial.current, cornerRadius: 14))
        .environment(\.locale, model.language.locale)
    }

    // MARK: Parts

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            if let row = model.transformSubjectRow {
                RowIcon(row: row, thumbnail: row.kind == .image ? model.thumbnails.thumbnail(for: row.itemID) : nil)
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.transformSubjectRow?.title ?? "")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle(count: count))
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
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
            CommandIcon(icon: Self.icon(section.mark))
                .scaleEffect(0.85)
                .frame(width: 14, height: 14)
            Text(section.title)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Tokens.Colors.textSecondary)
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 4, trailing: 10))
    }

    /// The highlighted transform's output: a swatch beside a color's value, a thumbnail beside an
    /// image's format, a file's tile beside where it goes, otherwise up to three lines of text.
    @ViewBuilder private func result(_ command: ExtensionCommand) -> some View {
        HStack(spacing: 11) {
            if Self.makesFiles(command) {
                fileResult(command)
            } else {
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
    /// right. A verb too long for all three ("Download and copy") leaves "← Back" out (← and Esc
    /// still close the panel), and the panel keeps its width.
    private var footer: some View {
        let labels = model.transformKeyLabels
        return ViewThatFits(in: .horizontal) {
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
        .padding(.top, 4)
    }

    /// `fixed: false`: the label may shorten rather than widen the panel (the last resort).
    private func hint(_ keys: [String], _ label: String, fixed: Bool = true) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap($0) } }
            Text(label).lineLimit(1).fixedSize(horizontal: fixed, vertical: fixed)
        }
    }

    // MARK: Values

    /// The row's right side: an image's format and size, otherwise the one-line hint.
    private func hint(for command: ExtensionCommand) -> String? {
        if case .image(_, let uti, let width, let height)? = model.transformOutput(command) {
            return "\(Self.format(uti)) · \(width)×\(height)"
        }
        return model.transformHint(command)
    }

    /// Image outputs, readings of an image (OCR), files and jobs are prose (a format, a description);
    /// everything else reads as code.
    static func isPlain(_ command: ExtensionCommand) -> Bool {
        command.output == .image || makesFiles(command) || command.isJob || command.accepts?.kinds.contains("image") == true
    }

    /// A target section's glyph names the kind of app (no app icons: headers stay grey).
    static func icon(_ mark: TransformSection.Mark) -> String {
        switch mark {
        case .icon(let icon): icon
        case .target(.finder): "sf:folder"
        case .target(.terminal): "sf:terminal"
        case .target(.browser): "sf:globe"
        case .target(.editor): "sf:doc.text"
        case .target(.other): "sf:macwindow"
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
