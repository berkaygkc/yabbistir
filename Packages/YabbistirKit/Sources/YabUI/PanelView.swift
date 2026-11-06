import SwiftUI
import YabCore
import YabLocalization

/// The panel's glass sheet: search row, the column strip (History, then categories) and the
/// action bar. The sheet fills its window; the window controller sizes it in whole columns.
public struct PanelView: View {
    @Bindable var model: PanelViewModel
    let material: PanelMaterial
    /// Clicks that leave the panel (paste a row, open the editor) go to the window controller.
    let onAction: (PanelAction) -> Void
    /// Snapshot rendering: ImageRenderer cannot draw ScrollView or AppKit blur views.
    var snapshot = false

    public init(model: PanelViewModel, material: PanelMaterial, onAction: @escaping (PanelAction) -> Void = { _ in }) {
        self.model = model
        self.material = material
        self.onAction = onAction
    }

    private func paste(_ id: Int64) {
        if let action = model.pasteAction(rowID: id, plain: false) { onAction(action) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchRow
            Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5)
            strip
            ActionBarView(model: model, onPaste: paste, onAction: onAction)
        }
        .overlay(alignment: .topTrailing) {
            if model.layer == .categoryMenu {
                CategoryMenuView(model: model, onAction: onAction)
                    .padding(.top, Tokens.Metrics.searchHeight - 7)
                    .padding(.trailing, 12)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.layer == .actions {
                // Inside the sheet, 8 pt below its top at most: a taller menu scrolls.
                ActionMenuView(model: model, maxHeight: model.panelHeight - Tokens.Metrics.footerHeight - 4 - 8, onAction: onAction)
                    .padding(.bottom, Tokens.Metrics.footerHeight + 4)
                    .padding(.trailing, 8)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.14)), value: model.layer)
        .frame(width: snapshot ? model.sheetWidth : nil, height: model.panelHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelBackground(material: material, forceSolid: snapshot))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Metrics.panelRadius, style: .continuous))
        .onHover { model.pointer(inPanel: $0) }
        .scaleEffect(model.isPresented ? 1 : 0.962, anchor: model.growAnchor)
        .offset(y: model.isPresented ? 0 : -6)
        .opacity(model.isPresented ? 1 : 0)
        .environment(\.locale, model.language.locale)
        // ⌘K's search line tells an input method where it is; never in a snapshot.
        .environment(\.textInputAnchors, snapshot ? nil : model.textInputAnchors)
    }

    // MARK: Search

    private var searchRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Text(.typed(model.query, marked: model.markedText(in: .search)))
                    .font(Tokens.Fonts.search)
                    .tracking(Tokens.Fonts.searchTracking)
                    .foregroundStyle(Tokens.Colors.text)
                    .lineLimit(1)
                    .background {
                        if model.isQuerySelected {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Tokens.Colors.textSelection)
                                .padding(.horizontal, -1)
                        }
                    }
                // Hidden, not removed, so selecting never shifts the line.
                BlinkingCaret().opacity(model.isQuerySelected ? 0 : 1)
                if model.query.isEmpty, model.markedText(in: .search).isEmpty {
                    Text(L10n.string("panel.search.placeholder", model.language))
                        .font(Tokens.Fonts.search)
                        .tracking(Tokens.Fonts.searchTracking)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .padding(.leading, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Input methods compose here: behind the whole line, its leading edge where the text starts.
            .background { if !snapshot { PanelTextInput(model: model) } }
            if let count = model.resultCountText {
                Text(count).font(Tokens.Fonts.label).foregroundStyle(Tokens.Colors.textSecondary).monospacedDigit()
            }
            CategoryDropdown(model: model)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: Tokens.Metrics.searchHeight)
    }

    // MARK: Columns

    /// Every column is laid out at full width; when they do not all fit, the strip slides in
    /// whole-column steps so the focused one is on screen. Columns keep their identity, so
    /// switching focus never resets a list's scroll position.
    private var strip: some View {
        // The strip lives in an overlay, so its full width (all columns) never sizes the sheet.
        Color.clear.overlay(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(Array(model.columns.enumerated()), id: \.element.id) { index, column in
                    ColumnView(column: column, isFocused: index == model.focusedColumn, model: model,
                               snapshot: snapshot, onPaste: paste)
                        .frame(width: ColumnStripLayout.columnWidth)
                        .overlay(alignment: .leading) {
                            if index > 0 { Rectangle().fill(Tokens.Colors.hairline).frame(width: 0.5) }
                        }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -14)), removal: .opacity))
                }
            }
            .offset(x: -CGFloat(model.firstVisibleColumn) * ColumnStripLayout.columnWidth)
            .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.32)), value: model.firstVisibleColumn)
            .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.42)), value: model.columns.map(\.id))
            // ←/→ at the first or last column: the columns bump sideways (a 240 ms nudge);
            // moving the content, not the sheet, keeps the rounded corners intact.
            .keyframeAnimator(initialValue: CGFloat(0), trigger: model.edgeNudge) { content, x in
                content.offset(x: x)
            } keyframes: { _ in
                CubicKeyframe(Tokens.Motion.reduceMotion() ? 0 : 5 * CGFloat(model.edgeNudgeDirection), duration: 0.12)
                CubicKeyframe(0, duration: 0.12)
            }
        }
        .clipped()
        .onPreferenceChange(SelectedRowFrameKey.self) { frame in
            MainActor.assumeIsolated { model.selectedRowFrame = frame }
        }
    }
}

public struct Keycap: View {
    let label: String
    let size: CGFloat
    let font: Font
    private var radius = Tokens.Metrics.keycapRadius
    private var inset: CGFloat = 5
    private var legend = Tokens.Colors.textSecondary
    /// `size` 18 with an 11 pt legend is the inline keycap in a job's title ("Hazır, ⌘V ile yapıştır").
    public init(_ label: String, size: CGFloat = 20, font: Font = Tokens.Fonts.keycap) {
        self.label = label
        self.size = size
        self.font = font
    }

    /// The large flat keycap of the first-run shortcut row: 34 pt, 8 pt corners, a 15/600 legend in `text`,
    /// no shadow or offset.
    public static func large(_ label: String) -> Keycap {
        var keycap = Keycap(label, size: 34, font: .system(size: 15, weight: .semibold))
        keycap.radius = Tokens.Metrics.controlRadius
        keycap.inset = 9
        keycap.legend = Tokens.Colors.text
        return keycap
    }

    public var body: some View {
        Text(label)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(legend)
            .padding(.horizontal, inset)
            .frame(minWidth: size, minHeight: size)
            .background(Tokens.Colors.keycapFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The yabbistir mark: a magenta tile with the keycap glyph.
public struct AppMark: View {
    public init() {}

    public var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(LinearGradient(colors: [Tokens.Colors.appMarkTop, Tokens.Colors.appMarkBottom], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: "keyboard").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .frame(width: 18, height: 18)
    }
}

struct ActionButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Tokens.Colors.keycapFill : .clear,
                        in: RoundedRectangle(cornerRadius: Tokens.Metrics.controlRadius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// The search caret: a 2 pt bar that blinks like the system's (1.06 s period).
struct BlinkingCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { context in
            let visible = Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(Tokens.Colors.text)
                .frame(width: 2, height: 20)
                .opacity(visible ? 1 : 0)
        }
        .padding(.leading, 1)
    }
}
