import AppKit
import ImageIO
import SwiftUI
import YabExtensionKit
import YabCore
import YabLocalization

/// The preview (400 pt glass): the item on top — text, highlighted code,
/// image, color swatch, link card or files — then a quiet Info table. Opened from the keyboard,
/// it ends with a hint bar.
public struct PreviewView: View {
    let content: PreviewContent
    let language: AppLanguage
    var showsHints = false
    /// Measuring pass: no scroll view and a short text head, so the window can size to fit.
    var measuring = false
    /// Pointer over the preview (keeps a hover preview open). A parameter, not a modifier, so the
    /// window's root view keeps one type and SwiftUI updates it instead of rebuilding it.
    var onHover: (Bool) -> Void = { _ in }

    public init(content: PreviewContent, language: AppLanguage, showsHints: Bool = false, measuring: Bool = false,
                onHover: @escaping (Bool) -> Void = { _ in }) {
        self.content = content
        self.language = language
        self.showsHints = showsHints
        self.measuring = measuring
        self.onHover = onHover
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if measuring {
                details
            } else {
                ScrollView(.vertical) { details.background(OverlayScrollerStyle()) }
                    .scrollIndicators(.automatic)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.94),
                                                 .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
            if showsHints { hints }
        }
        .frame(width: 400)
        .background(PanelBackground(material: PanelMaterial.current, cornerRadius: Tokens.Metrics.panelRadius))
        .onHover(perform: onHover)
        .environment(\.locale, language.locale)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            item
            extensionSections
            Text(L10n.string("preview.info", language))
                .font(Tokens.Fonts.section)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .padding(.top, 18)
                .padding(.bottom, 4)
            info
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The item

    @ViewBuilder private var item: some View {
        switch content.body {
        case .text(let text, let hidden):
            // Framed like a code block (so it reads as content, not as the window's title), in
            // the text face rather than the monospaced one.
            VStack(alignment: .leading, spacing: 8) {
                Text(measuring ? String(text.prefix(3000)) : text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Tokens.Colors.text)
                    .textSelection(.enabled)
                    .contentBlock()
                hiddenNote(hidden)
            }
        case .code(let tokens, let hidden):
            VStack(alignment: .leading, spacing: 8) {
                Text(highlighted(measuring ? Array(tokens.prefix(400)) : tokens))
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .contentBlock()
                hiddenNote(hidden)
            }
        case .image(let image, _):
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
            }
        case .color(let color):
            let swatch = Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(swatch).frame(height: 200)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
                HStack(spacing: 8) {
                    contrastSample(swatch, on: .white)
                    contrastSample(swatch, on: Color(.sRGB, red: 17 / 255, green: 17 / 255, blue: 20 / 255))
                }
            }
        case .link(let title, let url, let host):
            VStack(alignment: .leading, spacing: 0) {
                // No network: a calm field in the host's color instead of a page image.
                LinearGradient(colors: [LetterTile.color(for: host), Color(.sRGB, red: 13 / 255, green: 13 / 255, blue: 18 / 255)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 150)
                VStack(alignment: .leading, spacing: 3) {
                    if let title { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.Colors.text) }
                    Text(url).font(.system(size: 11.5)).foregroundStyle(Tokens.Colors.textSecondary).lineLimit(3)
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            }
            .background(Tokens.Colors.tile)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
        case .files(let urls, let thumbnail):
            VStack(alignment: .leading, spacing: 12) {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Text(urls.map(\.lastPathComponent).joined(separator: "\n"))
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Tokens.Colors.text)
            }
        case .command(let command):
            commandBody(command)
        }
    }

    // MARK: A command

    /// A generator: what it will paste, large. A transformer: its input, the extension, its output.
    @ViewBuilder private func commandBody(_ command: CommandPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let input = command.input {
                outputHeader("preview.command.input")
                commandInput(input)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold))
                    Text(command.extensionName)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Tokens.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                outputHeader("preview.command.output")
                commandOutput(command.output, large: false)
            } else {
                outputHeader("preview.command.output")
                commandOutput(command.output, large: true)
            }
        }
    }

    private func outputHeader(_ key: String) -> some View {
        Text(L10n.string(key, language))
            .font(Tokens.Fonts.section)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .padding(.bottom, 7)
    }

    @ViewBuilder private func commandInput(_ input: CommandPreview.Input) -> some View {
        switch input {
        case .text(let text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(5)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .contentBlock()
        case .color(let color):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 22, height: 22)
                Text(color.hex).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tokens.Colors.text)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .blockGround()
        case .image(let image):
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 126)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    @ViewBuilder private func commandOutput(_ output: CommandPreview.Output, large: Bool) -> some View {
        switch output {
        case .text(let text) where large:
            Text(measuring ? String(text.prefix(3000)) : text)
                .font(.system(size: 14.5, design: .monospaced))
                .tracking(0.15)
                .lineSpacing(7)
                .multilineTextAlignment(.center)
                .foregroundStyle(Tokens.Colors.text)
                .textSelection(.enabled)
                .padding(EdgeInsets(top: 20, leading: 14, bottom: 20, trailing: 14))
                .frame(maxWidth: .infinity)
                .blockGround()
        case .text(let text):
            Text(measuring ? String(text.prefix(3000)) : text)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(5)
                .foregroundStyle(Tokens.Colors.text)
                .textSelection(.enabled)
                .contentBlock()
        case .image(let image, let label):
            VStack(spacing: 8) {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Text(label).font(Tokens.Fonts.label).monospacedDigit().foregroundStyle(Tokens.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
        case .runsWhenUsed:
            Text(L10n.string("preview.command.runsWhenUsed", language))
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, large ? 24 : 14)
                .padding(.horizontal, 14)
                .blockGround()
        case .pending:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: large ? 64 : 44)
                .blockGround()
        }
    }

    @ViewBuilder private func hiddenNote(_ hidden: Int) -> some View {
        if hidden > 0 {
            Text("… " + L10n.string("preview.hidden", language, NumberFormatting.count(hidden, language: language)))
                .font(Tokens.Fonts.label)
                .foregroundStyle(Tokens.Colors.textSecondary)
        }
    }

    private func contrastSample(_ color: Color, on ground: Color) -> some View {
        Text("Aa")
            .font(.system(size: 22, weight: .bold))
            .tracking(-0.4)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
    }

    private func highlighted(_ tokens: [SyntaxToken]) -> AttributedString {
        var result = AttributedString()
        for token in tokens {
            var piece = AttributedString(token.text)
            switch token.kind {
            case .keyword:
                piece.foregroundColor = Tokens.Colors.syntaxKeyword
                piece.font = .system(size: 12, weight: .semibold, design: .monospaced)
            case .string: piece.foregroundColor = Tokens.Colors.syntaxString
            case .number: piece.foregroundColor = Tokens.Colors.syntaxNumber
            case .comment: piece.foregroundColor = Tokens.Colors.syntaxComment
            case .plain: piece.foregroundColor = Tokens.Colors.text
            }
            result += piece
        }
        return result
    }

    // MARK: Extension sections (the output header, the item's framed block)

    @ViewBuilder private var extensionSections: some View {
        ForEach(Array(content.extensionSections.enumerated()), id: \.offset) { _, section in
            VStack(alignment: .leading, spacing: 7) {
                Text(Self.title(of: section))
                    .font(Tokens.Fonts.section)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                sectionBody(section)
            }
            .padding(.top, 16)
        }
    }

    @ViewBuilder private func sectionBody(_ section: PreviewSection) -> some View {
        switch section {
        case .text(_, let text):
            Text(String(text.prefix(PreviewLoader.textLimit))).font(.system(size: 13)).lineSpacing(3)
                .foregroundStyle(Tokens.Colors.text).textSelection(.enabled).contentBlock()
        case .code(_, let code, _):
            Text(String(code.prefix(PreviewLoader.codeLimit))).font(.system(size: 12, design: .monospaced)).lineSpacing(5)
                .foregroundStyle(Tokens.Colors.text).textSelection(.enabled).contentBlock()
        case .keyValue(_, let rows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(row.first ?? "").foregroundStyle(Tokens.Colors.textSecondary).frame(width: 92, alignment: .leading)
                        Text(row.dropFirst().joined(separator: " ")).foregroundStyle(Tokens.Colors.text).textSelection(.enabled)
                    }
                    .font(.system(size: 12.5))
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentBlock()
        case .image(_, let data):
            if let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .link(_, let url):
            Text(url).font(.system(size: 12.5)).foregroundStyle(Tokens.Colors.text).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).contentBlock()
        }
    }

    private static func title(of section: PreviewSection) -> String {
        switch section {
        case .text(let title, _), .code(let title, _, _), .keyValue(let title, _), .image(let title, _), .link(let title, _): title
        }
    }

    // MARK: Info table (92 pt labels, rows split by hairlines)

    private var info: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(content.info.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(row.label).foregroundStyle(Tokens.Colors.textSecondary).frame(width: 92, alignment: .leading)
                    HStack(spacing: 6) {
                        if let bundleID = row.appBundleID, let icon = Self.icon(for: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 14, height: 14).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        }
                        ForEach(Array(row.categoryColors.enumerated()), id: \.offset) { _, color in
                            Circle().fill(Tokens.Colors.category(color)).frame(width: 7, height: 7)
                        }
                        if row.chips.isEmpty {
                            Text(row.value)
                                .foregroundStyle(Tokens.Colors.text)
                                .monospacedDigit()
                                .textSelection(.enabled)
                        } else {
                            ChipFlow(spacing: 4) { ForEach(row.chips, id: \.self) { TagChip(text: $0) } }
                                .alignmentGuide(.firstTextBaseline) { $0[.top] + 13 }
                        }
                    }
                }
                .font(.system(size: 12.5))
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 33, alignment: .topLeading)
                .overlay(alignment: .top) { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5) }
            }
        }
    }

    /// The source app's icon, from the local app bundle (no network).
    private static func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint("␣", "preview.close")
            hint("↵", "panel.footer.paste")
            Spacer(minLength: 0)
        }
        .font(Tokens.Fonts.label)
        .foregroundStyle(Tokens.Colors.textSecondary)
        .padding(EdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18))
        .overlay(alignment: .top) { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Keycap(key)
            Text(L10n.string(label, language))
        }
    }
}

private extension View {
    /// The preview's content block: tile ground, 12 pt corners,
    /// hairline edge, 14/16 pt padding.
    func contentBlock() -> some View {
        padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .blockGround()
    }

    /// The block's ground and edge, for blocks with their own padding.
    func blockGround() -> some View {
        background(Tokens.Colors.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
    }
}
