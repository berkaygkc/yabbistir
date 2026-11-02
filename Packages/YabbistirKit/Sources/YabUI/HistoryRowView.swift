import SwiftUI
import YabCore

/// One single-line history row: type icon · title · tags · (iPhone) · time.
struct HistoryRowView: View {
    let row: RowModel
    let query: String
    /// A 40 px thumbnail for image rows, once it is ready.
    var thumbnail: CGImage? = nil
    /// 1…9 while ⌘ is held: the keycap takes the icon's 20 pt slot, so the row never shifts.
    var indexKey: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Group {
                    if let number = row.stackNumber { StackNumberKey(number: number, isNext: number == 1) } else { RowIcon(row: row, thumbnail: thumbnail) }
                }
                    .scaleEffect(indexKey == nil ? 1 : 0.8)
                    .opacity(indexKey == nil ? 1 : 0)
                if let indexKey {
                    Keycap("\(indexKey)")
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: Tokens.Metrics.iconSize, height: Tokens.Metrics.iconSize)
            .animation(Tokens.Motion.resolved(Tokens.Motion.spring(0.26)), value: indexKey)
            Text(attributedTitle)
                .font(row.kind == .code ? Tokens.Fonts.mono : Tokens.Fonts.row)
                .foregroundStyle(Tokens.Colors.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if !row.tags.isEmpty {
                    HStack(spacing: 4) { ForEach(row.tags, id: \.self) { TagChip(text: $0) } }
                        .padding(.trailing, 2)
                }
                if row.isRemote {
                    Image(systemName: "iphone").font(.system(size: 11)).accessibilityLabel("iPhone")
                }
                Text(row.time).font(Tokens.Fonts.label).monospacedDigit()
            }
            .foregroundStyle(Tokens.Colors.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: Tokens.Metrics.rowHeight)
        .contentShape(Rectangle())
    }

    private var attributedTitle: AttributedString { Self.highlighted(row.title, query: query) }

    /// `string` with what the query matches (Turkish-folded) marked.
    static func highlighted(_ string: String, query: String) -> AttributedString {
        var text = AttributedString(string)
        for range in PanelViewModel.highlights(in: string, query: query) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].backgroundColor = Tokens.Colors.matchHighlight
        }
        return text
    }
}

struct RowIcon: View {
    let row: RowModel
    var thumbnail: CGImage? = nil

    var body: some View {
        Group {
            switch row.kind {
            case .color:
                Circle().fill(Color(hex: row.colorHex) ?? .gray)
                    .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
            case .link:
                LetterTile(host: row.linkHost)
            case .image where thumbnail != nil:
                Image(decorative: thumbnail!, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Tokens.Metrics.iconSize, height: Tokens.Metrics.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Metrics.keycapRadius, style: .continuous))
            default:
                Image(systemName: Self.symbol(for: row.kind))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Tokens.Colors.textSecondary)
            }
        }
        .frame(width: Tokens.Metrics.iconSize, height: Tokens.Metrics.iconSize)
    }

    static func symbol(for kind: ItemKind) -> String {
        switch kind {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .file: "doc"
        case .link: "link"
        case .text, .color: "text.alignleft"
        }
    }
}

/// Favicon stand-in: the host's initial on a color derived from the host (no network).
struct LetterTile: View {
    let host: String?

    /// A stable color per host (the preview's link card uses it too).
    static func color(for host: String?) -> Color {
        let name = (host ?? "?").replacingOccurrences(of: "www.", with: "")
        return palette[abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count]
    }
    private static let palette: [Color] = [
        rgba(94, 106, 210, 1), rgba(36, 41, 47, 1), rgba(244, 104, 0, 1),
        rgba(54, 45, 89, 1), rgba(29, 136, 229, 1), rgba(47, 181, 81, 1),
    ]

    var body: some View {
        let name = (host ?? "?").replacingOccurrences(of: "www.", with: "")
        let color = Self.color(for: host)
        RoundedRectangle(cornerRadius: Tokens.Metrics.keycapRadius, style: .continuous)
            .fill(color)
            .overlay(Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white))
    }
}

extension Color {
    /// "#RRGGBB" or bare "RRGGBB".
    init?(hex: String?) {
        guard let hex, let value = ColorValue(hex: hex) else { return nil }
        self = rgba(Double(value.red), Double(value.green), Double(value.blue), 1)
    }
}
