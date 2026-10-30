import AppKit
import SwiftUI

/// A command row: icon · title · hint, and the extension's name on the
/// right where items show their time.
struct CommandRowView: View {
    let command: CommandRowInfo
    /// 1…9 while ⌘ is held, in the icon's slot like an item row.
    var indexKey: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CommandIcon(icon: command.icon)
                    .scaleEffect(indexKey == nil ? 1 : 0.8)
                    .opacity(indexKey == nil ? 1 : 0)
                if let indexKey {
                    Keycap("\(indexKey)")
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: Tokens.Metrics.iconSize, height: Tokens.Metrics.iconSize)
            .animation(Tokens.Motion.resolved(Tokens.Motion.spring(0.26)), value: indexKey)
            HStack(spacing: 9) {
                Text(command.title)
                    .font(Tokens.Fonts.row)
                    .foregroundStyle(Tokens.Colors.text)
                    .layoutPriority(1)
                if let hint = command.hint, !hint.isEmpty {
                    Text(String(hint.prefix(60)))
                        .font(command.hintIsMono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                        .foregroundStyle(Tokens.Colors.textSecondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            TagChip(text: command.extensionName)
        }
        .padding(.horizontal, 10)
        .frame(height: Tokens.Metrics.rowHeight)
        .contentShape(Rectangle())
    }
}

/// An extension's icon: an SF Symbol in the secondary color, or its PNG at 16 pt. `size` is the
/// symbol's point size (the PNG scales with it); a job's tile draws a 15 px icon at 12.
struct CommandIcon: View {
    let icon: String
    var size: CGFloat = 13
    var color: Color = Tokens.Colors.textSecondary

    var body: some View {
        if icon.hasPrefix("sf:") {
            Image(systemName: String(icon.dropFirst(3)))
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(color)
        } else if let image = Self.image(at: icon) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 16 * size / 13, height: 16 * size / 13)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(color)
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private static func image(at path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = image
        return image
    }
}

/// The small grey chip for an extension's name and an item's tags.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.1)
            .foregroundStyle(Tokens.Colors.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Tokens.Colors.keycapFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Chips left to right, wrapping onto a new line when the row is full.
struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(place(subviews, width: bounds.width), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
