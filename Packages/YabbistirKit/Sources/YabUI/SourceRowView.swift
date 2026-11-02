import SwiftUI
import YabLocalization

/// One of a source's rows (a vault's entry), one line like every row: the title's initial on a grey tile, the title,
/// and the subtitle (a username) where an item shows its time. A row carries no value, so none is ever drawn.
struct SourceRowView: View {
    let row: RowModel
    let subtitle: String?
    let query: String
    /// 1…9 while ⌘ is held: the keycap takes the tile's slot, as on a history row.
    var indexKey: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                InitialTile(title: row.title)
                    .scaleEffect(indexKey == nil ? 1 : 0.8)
                    .opacity(indexKey == nil ? 1 : 0)
                if let indexKey {
                    Keycap("\(indexKey)")
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: Tokens.Metrics.iconSize, height: Tokens.Metrics.iconSize)
            .animation(Tokens.Motion.resolved(Tokens.Motion.spring(0.26)), value: indexKey)
            Text(HistoryRowView.highlighted(row.title, query: query))
                .font(Tokens.Fonts.row)
                .foregroundStyle(Tokens.Colors.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let subtitle, !subtitle.isEmpty {
                // Its own width up to 170 pt; the title gives way first.
                Text(HistoryRowView.highlighted(subtitle, query: query))
                    .font(Tokens.Fonts.label)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 170, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Tokens.Metrics.rowHeight)
        .contentShape(Rectangle())
    }
}

/// The mark of a source's category where other categories show their hue: a key lying on its diagonal, bow at the
/// lower left (SF Symbols' `key` stands upright, so it is turned). The turn draws only: the layout box stays the
/// upright symbol's, so nothing beside it moves. Coloured by the caller.
struct SourceMark: View {
    /// The symbol's point size: 10 in a column header.
    var size: CGFloat = 10

    var body: some View {
        Image(systemName: "key")
            .font(.system(size: size, weight: .regular))
            .rotationEffect(.degrees(-135))
    }
}

/// A source row's stand-in for a site icon: the title's first letter on the panel's grey tile. Rows carry no URL and
/// the extension may not reach the network, so there is no favicon; a column of coloured tiles would also be loud.
struct InitialTile: View {
    let title: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Metrics.keycapRadius, style: .continuous)
        shape.fill(Tokens.Colors.tile)
            .overlay(shape.strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
            .overlay(Text(Self.initial(of: title))
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Tokens.Colors.textSecondary))
            .frame(width: Tokens.Metrics.iconSize, height: Tokens.Metrics.iconSize)
    }

    /// "iş portalı" → "İ": Turkish capitals, whatever the app's language.
    static func initial(of title: String) -> String {
        String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased(with: Locale(identifier: "tr"))
    }
}

/// A locked source's one calm row: a lock and the extension's message, and under it, in the secondary colour, the
/// line the person runs in Terminal to unlock it (⌘C copies it). Two lines, 56 pt: the text does not fit one at the
/// column's width. Without a command it is the message alone, on one 40 pt line.
struct LockedSourceRowView: View {
    let message: String
    let command: String?
    let language: AppLanguage

    static let height: CGFloat = 56

    var body: some View {
        HStack(alignment: command == nil ? .center : .top, spacing: 12) {
            Image(systemName: "lock")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.Colors.textSecondary)
                .frame(width: Tokens.Metrics.iconSize, height: command == nil ? Tokens.Metrics.iconSize : 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(Tokens.Fonts.row)
                    .foregroundStyle(Tokens.Colors.text)
                    .frame(height: 18)
                if let command {
                    Text(commandLine(command))
                        .font(Tokens.Fonts.label)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .frame(height: 16)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: command == nil ? Tokens.Metrics.rowHeight : Self.height)
        .contentShape(Rectangle())
    }

    /// "Terminal’de <command>", the command in monospace.
    private func commandLine(_ command: String) -> AttributedString {
        var line = AttributedString(L10n.string("panel.source.inTerminal", language) + " ")
        var code = AttributedString(command)
        code.font = .system(size: 11.5, design: .monospaced)
        line.append(code)
        return line
    }
}
