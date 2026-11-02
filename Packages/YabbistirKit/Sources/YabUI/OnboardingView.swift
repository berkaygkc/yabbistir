import AppKit
import SwiftUI
import YabCore
import YabImport
import YabLocalization
import YabPlatform

/// The first-run window's content: the step dots in a 44 pt bar (the system's traffic lights sit at its left), then one
/// step at a time. Each step slides in from the right and keeps its actions at the bottom. The view is as tall as its
/// step needs, never shorter than a 430 pt body; the window follows that height.
public struct OnboardingView: View {
    let model: OnboardingModel
    /// Snapshot rendering: an opaque surface (an offscreen window draws no glass) and no entrance motion.
    var snapshot = false

    public init(model: OnboardingModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            StepDots(count: model.dots, active: model.activeDot)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: Onboarding.barHeight, maxHeight: Onboarding.barHeight, alignment: .trailing)
            step
                .modifier(PaneEntrance(still: snapshot))
                .id(model.step)
                .padding(EdgeInsets(top: 6, leading: Onboarding.side, bottom: 30, trailing: Onboarding.side))
        }
        .frame(width: Onboarding.width)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Tokens.Colors.text)
        .monospacedDigit()
        .background(PanelBackground(material: PanelMaterial.current, cornerRadius: Onboarding.radius, forceSolid: snapshot))
        .clipShape(RoundedRectangle(cornerRadius: Onboarding.radius, style: .continuous))
        .environment(\.locale, model.language.language.locale)
        .ignoresSafeArea()
    }

    @ViewBuilder private var step: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .importChoice: ImportChoiceStep(model: model, importer: model.importer)
        case .importing: ImportingStep(model: model)
        case .setup: SetupStep(model: model, importer: model.importer)
        }
    }
}

/// The window's measures.
enum Onboarding {
    static let width: CGFloat = 620
    static let radius: CGFloat = 24
    static let barHeight: CGFloat = 44
    static let side: CGFloat = 48
    /// The body is at least 430 pt with its 6 + 30 pt padding.
    static let columnMinHeight: CGFloat = 430 - 36
    /// The gap the actions keep above them, however full the step.
    static let actionsGap: CGFloat = 26
    static let paragraphWidth: CGFloat = 470
}

// MARK: - Steps

private struct WelcomeStep: View {
    let model: OnboardingModel

    var body: some View {
        StepColumn {
            VStack(alignment: .leading, spacing: 0) {
                AppIcon()
                    .padding(.top, 18)
                    .padding(.bottom, 22)
                BalancedText(text: string("onboarding.welcome.title"), style: .display, maxWidth: 460)
                Text(string("onboarding.welcome.body"))
                    .typeStyle(.bodyLarge)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .frame(maxWidth: Onboarding.paragraphWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                LanguagePicker(store: model.language)
                    .padding(.top, 18)
            }
            HStack(spacing: 10) {
                PrimaryButton(title: string("onboarding.welcome.start"), arrow: true) { model.next() }
                Spacer(minLength: 0)
                if model.showsPasteHint {
                    Text(string("onboarding.welcome.importHint"))
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .animation(.plainEase(0.2), value: model.showsPasteHint)
        }
    }

    private func string(_ key: String) -> String { L10n.string(key, model.language.language) }
}

private struct ImportChoiceStep: View {
    let model: OnboardingModel
    @Bindable var importer: ImportModel

    var body: some View {
        StepColumn {
            VStack(alignment: .leading, spacing: 0) {
                StepHeader(title: string("import.title"), detail: string("import.body"))
                Group {
                    switch importer.state {
                    case .ready(let summary, _): library(summary)
                    case .failed: QuietLine(text: string("import.error"), busy: false)
                    case .unavailable: QuietLine(text: string("import.none"), busy: false)
                    default: QuietLine(text: string("import.scanning"), busy: true)
                    }
                }
                .padding(.top, 18)
            }
            .animation(.plainEase(0.2), value: isReady)
            HStack(spacing: 10) {
                PrimaryButton(title: string("import.start"), enabled: model.primaryEnabled) { model.next() }
                GhostButton(title: string("import.skip")) { model.skipImport() }
                Spacer(minLength: 0)
            }
        }
    }

    private var isReady: Bool {
        if case .ready = importer.state { true } else { false }
    }

    private func library(_ summary: PasteSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SourceCard(importer: importer)
            choices(summary)
                .padding(.top, 14)
            if !importer.noteLine.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tag").font(.system(size: 12))
                    Text(importer.noteLine)
                }
                .font(.system(size: 12))
                .foregroundStyle(Tokens.Colors.textSecondary)
                .padding(.top, 12)
            }
        }
        .transition(.opacity)
    }

    /// "Whole history" across both columns, then the pinboards two by two. More than three rows of pinboards scroll,
    /// so a large library never grows the window.
    private func choices(_ summary: PasteSummary) -> some View {
        let rows = stride(from: 0, to: summary.boards.count, by: 2).map { Array(summary.boards[$0..<min($0 + 2, summary.boards.count)]) }
        let grid = VStack(spacing: 6) {
            ForEach(rows, id: \.first?.id) { pair in
                HStack(spacing: 6) {
                    ForEach(pair) { board in
                        ChoiceRow(name: board.name, count: importer.boardCountText(board), whole: false, isOn: boardBinding(board.id))
                    }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
        return VStack(spacing: 6) {
            ChoiceRow(name: string("import.allHistory"), count: importer.itemsPhrase(summary.historyCount), whole: true,
                      isOn: $importer.selection.history)
            if rows.count > Self.visibleRows {
                ScrollView { grid.background(OverlayScrollerStyle()) }
                    .frame(height: CGFloat(Self.visibleRows) * ChoiceRow.height + CGFloat(Self.visibleRows - 1) * 6)
                    .scrollIndicatorsFlash(onAppear: true)
            } else {
                grid
            }
        }
    }

    private static let visibleRows = 3

    private func boardBinding(_ id: Int64) -> Binding<Bool> {
        Binding(get: { importer.selection.boards.contains(id) },
                set: { on in if on { importer.selection.boards.insert(id) } else { importer.selection.boards.remove(id) } })
    }

    private func string(_ key: String) -> String { L10n.string(key, model.language.language) }
}

private struct ImportingStep: View {
    let model: OnboardingModel
    /// The figures on screen: they follow the import's progress and stay put if it fails.
    @State private var figures: ImportFigures

    init(model: OnboardingModel) {
        self.model = model
        _figures = State(initialValue: ImportFigures(model.importer.state) ?? ImportFigures())
    }

    var body: some View {
        StepColumn {
            VStack(alignment: .leading, spacing: 0) {
                StepHeader(title: string(isDone ? "import.done.title" : "import.progress.title"), detail: string("import.progress.body"))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    CountingText(value: Double(figures.done), language: language)
                        .typeStyle(.counter)
                    Text(L10n.string("import.progress.of", language, model.importer.itemsPhrase(figures.total)))
                        .font(.system(size: 15))
                        .foregroundStyle(Tokens.Colors.textSecondary)
                }
                .padding(.top, 26)
                ImportBar(fraction: figures.fraction)
                    .padding(.top, 18)
                ChipFlow(spacing: 6) {
                    ForEach(ImportFigures.kindOrder, id: \.self) { kind in
                        KindChip(label: string(Self.kindKey(kind)), count: figures.kinds[kind] ?? 0, language: language)
                    }
                }
                .padding(.top, 18)
                if let line = problemLine {
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.Colors.textSecondary)
                        .padding(.top, 12)
                }
                ZStack {
                    if isDone {
                        DoneMark().transition(Tokens.Motion.reduceMotion() ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .padding(.top, isDone ? 24 : 0)
                .animation(Tokens.Motion.resolved(Tokens.Motion.spring(0.5)) ?? .plainEase(0.2), value: isDone)
            }
            .animation(Tokens.Motion.resolved(.easeOutCubic(0.3)), value: figures)
            HStack(spacing: 10) {
                PrimaryButton(title: string("onboarding.continue"), enabled: model.primaryEnabled) { model.next() }
                Spacer(minLength: 0)
            }
        }
        .onChange(of: model.importer.state) { _, state in
            if let next = ImportFigures(state) { figures = next }
        }
    }

    private var language: AppLanguage { model.language.language }

    private var isDone: Bool {
        if case .done = model.importer.state { true } else { false }
    }

    /// Items that could not come, or why the import stopped.
    private var problemLine: String? {
        if case .failed = model.importer.state { return string("import.error") }
        return model.importer.failedLine
    }

    private static func kindKey(_ kind: ItemKind) -> String {
        switch kind {
        case .text: "import.kind.text"
        case .code: "import.kind.code"
        case .link: "import.kind.link"
        case .image: "import.kind.image"
        case .color: "import.kind.color"
        case .file: "import.kind.file"
        }
    }

    private func string(_ key: String) -> String { L10n.string(key, language) }
}

/// What the importing step counts: items handled of all chosen, and the new items by kind.
private struct ImportFigures: Equatable {
    var done = 0
    var total = 0
    var kinds: [ItemKind: Int] = [:]

    /// In this order: text, code, link, image, color, file.
    static let kindOrder: [ItemKind] = [.text, .code, .link, .image, .color, .file]

    init() {}

    init?(_ state: ImportModel.State) {
        switch state {
        case .importing(let progress):
            done = progress.done
            total = progress.total
            kinds = progress.kinds
        case .done(let report):
            done = report.added + report.merged + report.skipped + report.failed
            total = done
            kinds = report.kinds
        default:
            return nil
        }
    }

    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }
}

private struct SetupStep: View {
    @Bindable var model: OnboardingModel
    let importer: ImportModel

    var body: some View {
        StepColumn {
            VStack(alignment: .leading, spacing: 0) {
                StepHeader(title: string("onboarding.setup.title"), detail: string("onboarding.setup.body"))
                VStack(spacing: 0) {
                    SettingRow(title: string("onboarding.setup.shortcut.title"), detail: string(model.shortcutSubtitleKey), divider: true) {
                        HStack(spacing: 5) {
                            ForEach(Array(GlobalShortcut.togglePanel.keycaps.enumerated()), id: \.offset) { Keycap.large($0.element) }
                        }
                    }
                    SettingRow(title: string("onboarding.setup.paste.title"), detail: string("onboarding.setup.paste.body"), divider: true) {
                        ZStack(alignment: .trailing) {
                            if model.accessibilityGranted {
                                GrantedPill(title: string("onboarding.setup.paste.allowed")).transition(.opacity)
                            } else {
                                GhostButton(title: string("onboarding.setup.paste.allow"), symbol: "checkmark.shield") {
                                    model.requestAccessibility()
                                }
                                .transition(.opacity)
                            }
                        }
                        .animation(.plainEase(0.2), value: model.accessibilityGranted)
                    }
                    SettingRow(title: string("onboarding.setup.login.title"), detail: string("onboarding.setup.login.body"),
                               divider: importer.otherAppRunning) {
                        Toggle(string("onboarding.setup.login.title"), isOn: $model.launchAtLogin)
                            .toggleStyle(SwitchStyle())
                    }
                    if importer.otherAppRunning {
                        SettingRow(title: string("import.running.title"), detail: string("import.running.body"), divider: false) {
                            GhostButton(title: string("import.running.quit")) { importer.quitOtherApp() }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.top, 18)
                .animation(.plainEase(0.2), value: importer.otherAppRunning)
            }
            HStack(spacing: 10) {
                PrimaryButton(title: string("onboarding.finish")) { model.finish() }
                Spacer(minLength: 0)
            }
        }
        // Accessibility is granted in System Settings and the other app may quit at any time: read both while the
        // step shows.
        .task {
            while !Task.isCancelled {
                model.refreshAccessibility()
                importer.refreshOtherApp()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func string(_ key: String) -> String { L10n.string(key, model.language.language) }
}

// MARK: - Layout

/// A step's column: its content from the top and its actions pinned to the bottom, at least the body's minimum tall.
/// The actions keep a 26 pt gap above them when the content fills the column.
private struct StepColumn: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Onboarding.width - 2 * Onboarding.side
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: max(Onboarding.columnMinHeight, heights.reduce(0, +) + Onboarding.actionsGap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let actions = subviews.last else { return }
        var y = bounds.minY
        for subview in subviews.dropLast() {
            let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
        let height = actions.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        actions.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: height))
    }
}

/// Segments of one width, the widest one's.
private struct EqualWidths: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = sizes.map(\.width).max() ?? 0
        return CGSize(width: width * CGFloat(subviews.count), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY),
                          proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

// MARK: - Type

/// A text style: size, weight, line height and letter spacing (in em).
struct OnboardingType {
    let size: CGFloat
    let weight: Font.Weight
    let lineHeight: CGFloat?
    let tracking: CGFloat

    /// Display: the welcome headline.
    static let display = OnboardingType(size: 27, weight: .bold, lineHeight: 33, tracking: -0.022)
    /// Headline: the other steps' titles.
    static let headline = OnboardingType(size: 21, weight: .bold, lineHeight: 27, tracking: -0.018)
    /// Body Large: the welcome paragraph.
    static let bodyLarge = OnboardingType(size: 14, weight: .regular, lineHeight: 21, tracking: 0)
    /// The smaller paragraph under a step title.
    static let bodySmall = OnboardingType(size: 13, weight: .regular, lineHeight: 19, tracking: 0)
    /// The import counter, set solid (line height 1).
    static let counter = OnboardingType(size: 56, weight: .bold, lineHeight: 56, tracking: -0.04)

    var font: Font { .system(size: size, weight: weight) }

    var nsFont: NSFont {
        NSFont.systemFont(ofSize: size, weight: weight == .bold ? .bold : weight == .semibold ? .semibold : .regular)
    }

    /// The font's own line height, the one SwiftUI sets a line in.
    var naturalLineHeight: CGFloat {
        let font = nsFont
        return font.ascender - font.descender + font.leading
    }

    /// What the line height adds to the font's own: between lines, and half of it above the first and below the last.
    var extraLeading: CGFloat { (lineHeight ?? naturalLineHeight) - naturalLineHeight }
}

extension View {
    func typeStyle(_ style: OnboardingType) -> some View {
        font(style.font)
            .tracking(style.tracking * style.size)
            .lineSpacing(max(0, style.extraLeading))
            .padding(.vertical, style.extraLeading / 2)
    }
}

/// Balanced wrapping (`text-wrap: balance`): the narrowest width up to `maxWidth` that keeps the same number of lines, so a headline
/// breaks into even lines instead of leaving one word alone.
private struct BalancedText: View {
    let text: String
    let style: OnboardingType
    let maxWidth: CGFloat

    var body: some View {
        Text(text)
            .typeStyle(style)
            .frame(width: Self.width(text, style: style, maxWidth: maxWidth), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func width(_ text: String, style: OnboardingType, maxWidth: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: style.nsFont, .kern: style.tracking * style.size])
        func lines(_ width: CGFloat) -> Int {
            let height = attributed.boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height
            return max(1, Int((height / style.naturalLineHeight).rounded()))
        }
        let target = lines(maxWidth)
        guard target > 1 else { return maxWidth }
        var low = maxWidth / CGFloat(target), high = maxWidth
        while high - low > 0.5 {
            let middle = (low + high) / 2
            if lines(middle) <= target { high = middle } else { low = middle }
        }
        // A little room for SwiftUI's own line breaking, never more than one character's worth.
        return min(maxWidth, ceil(high) + 2)
    }
}

// MARK: - Parts

/// The current step's dot is an 18 pt pill; the dots slide as the steps change.
private struct StepDots: View {
    let count: Int
    let active: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == active ? Tokens.Colors.text : Tokens.Colors.textTertiary)
                    .frame(width: index == active ? 18 : 6, height: 6)
            }
        }
        .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.3)), value: active)
        .accessibilityHidden(true)
    }
}

/// Each step comes in 18 pt from the right as it fades in (0.5 s); with Reduce Motion it only fades.
private struct PaneEntrance: ViewModifier {
    let still: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || still ? 1 : 0)
            .offset(x: shown || still || Tokens.Motion.reduceMotion() ? 0 : 18)
            .task {
                // A turn after the step appears, so the change is animated even in the window's first frame.
                guard !still else { return }
                withAnimation(Tokens.Motion.ease(0.5)) { shown = true }
            }
    }
}

private struct StepHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).typeStyle(.headline)
            Text(detail)
                .typeStyle(.bodySmall)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .frame(maxWidth: Onboarding.paragraphWidth, alignment: .leading)
                .padding(.top, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The app's own icon, its artwork 84 pt (an icon's artwork fills 824 of its 1024 pt canvas), with a soft shadow.
private struct AppIcon: View {
    var body: some View {
        let canvas = 84 * 1024 / 824.0
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .interpolation(.high)
            .frame(width: canvas, height: canvas)
            .frame(width: 84, height: 84)
            .shadow(color: .black.opacity(0.35), radius: 11, y: 12)
            .accessibilityHidden(true)
    }
}

/// English · Türkçe. Picking one turns the whole window (and the app) to it at once.
private struct LanguagePicker: View {
    let store: LanguageStore

    var body: some View {
        EqualWidths {
            ForEach(AppLanguage.allCases, id: \.self) { language in
                segment(language)
            }
        }
        .padding(2)
        .background(Tokens.Colors.tile, in: RoundedRectangle(cornerRadius: Tokens.Metrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Metrics.controlRadius, style: .continuous)
            .strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
        .fixedSize()
    }

    private func segment(_ language: AppLanguage) -> some View {
        let on = store.language == language
        let thumb = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button { store.language = language } label: {
            // The semibold copy holds the width, so choosing never changes it.
            ZStack {
                Text(language.nativeName).font(.system(size: 11.5, weight: .semibold)).hidden()
                Text(language.nativeName)
                    .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Tokens.Colors.text : Tokens.Colors.textSecondary)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background {
                if on {
                    thumb.fill(Tokens.Colors.surfaceSolid)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        .overlay(thumb.strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
                }
            }
            .contentShape(thumb)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The other library: a neutral clipboard tile, its name and folder, and how much it holds.
private struct SourceCard: View {
    let importer: ImportModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let tile = RoundedRectangle(cornerRadius: 11, style: .continuous)
        HStack(spacing: 14) {
            tile.fill(LinearGradient(colors: [rgba(92, 92, 102, 1), rgba(44, 44, 51, 1)], startPoint: .top, endPoint: .bottom))
                .overlay(tile.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .overlay(Image(systemName: "list.clipboard").font(.system(size: 17)).foregroundStyle(.white))
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(importer.sourceName).font(.system(size: 14, weight: .bold))
                Text(importer.sourceLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text(importer.number(importer.libraryItemCount)).font(.system(size: 20, weight: .bold)).tracking(-0.4)
                Text(importer.unitLine).font(.system(size: 12)).foregroundStyle(Tokens.Colors.textSecondary)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Tokens.Colors.tile, in: shape)
        .overlay(shape.strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
    }
}

/// A row of the import choice: a checkbox, the name, its count. The whole-history row is taller, filled and bold.
private struct ChoiceRow: View {
    static let height: CGFloat = 38
    let name: String
    let count: String
    let whole: Bool
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Button { isOn.toggle() } label: {
            HStack(spacing: 9) {
                Checkbox(isOn: isOn)
                Text(name)
                    .font(.system(size: 12.5, weight: whole ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(count)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: whole ? 42 : Self.height)
            .background(whole ? Tokens.Colors.tile : hovering ? Tokens.Colors.rowHover : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.plainEase(0.15), value: hovering)
        .accessibilityRepresentation { Toggle(name, isOn: $isOn) }
    }
}

/// 16 pt, 5 pt corners: `tile` with an edge when off, `system-accent` when on; the check springs in.
private struct Checkbox: View {
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack {
            shape.fill(isOn ? Tokens.Colors.systemAccent : Tokens.Colors.tile)
            shape.strokeBorder(Tokens.Colors.edge, lineWidth: 0.5).opacity(isOn ? 0 : 1)
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white)
                .opacity(isOn ? 1 : 0)
                .animation(.plainEase(0.15), value: isOn)
                .scaleEffect(isOn ? 1 : 0.6)
                .animation(Tokens.Motion.resolved(Tokens.Motion.spring(0.2)), value: isOn)
        }
        .frame(width: 16, height: 16)
        .animation(.plainEase(0.15), value: isOn)
    }
}

/// A number that counts its way to each new value.
private struct CountingText: View, Animatable {
    var value: Double
    let language: AppLanguage

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(GroupedCount.string(Int(value.rounded()), language: language))
    }
}

/// `NumberFormatting.count` with its formatter kept, for numbers that change every frame.
@MainActor
private enum GroupedCount {
    private static var formatters: [AppLanguage: NumberFormatter] = [:]

    static func string(_ value: Int, language: AppLanguage) -> String {
        let formatter = formatters[language] ?? {
            let formatter = NumberFormatter()
            formatter.locale = language.locale
            formatter.numberStyle = .decimal
            formatters[language] = formatter
            return formatter
        }()
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// An 8 pt `tile` track with a `system-accent` fill.
private struct ImportBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Tokens.Colors.tile)
            .overlay(Capsule().strokeBorder(Tokens.Colors.hairline, lineWidth: 0.5))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Tokens.Colors.systemAccent)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .clipShape(Capsule())
            .frame(height: 8)
    }
}

private struct KindChip: View {
    let label: String
    let count: Int
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Tokens.Colors.textSecondary)
            CountingText(value: Double(count), language: language).fontWeight(.semibold)
        }
        .font(.system(size: 12))
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 28)
        .background(Tokens.Colors.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize()
    }
}

private struct DoneMark: View {
    var body: some View {
        Circle()
            .fill(Tokens.Colors.success)
            .frame(width: 44, height: 44)
            .overlay(Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    let divider: Bool
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Tokens.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            control
        }
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5) }
        }
    }
}

private struct GrantedPill: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            Text(title)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(Tokens.Colors.success)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Tokens.Colors.success.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize()
    }
}

/// A line that stands in for the library while it is read, or says why it can't be.
private struct QuietLine: View {
    let text: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Tokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }
}

// MARK: - Controls

/// The default button: `system-accent`, 34 pt, 10 pt corners, a soft accent glow; dims to 40 % when disabled.
private struct PrimaryButton: View {
    let title: String
    var arrow = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if arrow { Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)) }
            }
        }
        .buttonStyle(OnboardingButtonStyle(primary: true))
        .disabled(!enabled)
    }
}

/// The secondary button: the same shape on `tile`, `row-hover` under the pointer.
private struct GhostButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13)) }
                Text(title)
            }
        }
        .buttonStyle(OnboardingButtonStyle(primary: false))
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? Color.white : Tokens.Colors.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background {
                if primary {
                    shape.fill(Tokens.Colors.systemAccent)
                        // 0 1px 0 rgba(255,255,255,.2) inset: a light top edge.
                        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0)],
                                                                   startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12)),
                                                    lineWidth: 1))
                        // 0 6px 16px -6px accent: the glow under the button, cast by a shape 6 pt smaller that the
                        // button itself hides.
                        .background(shape.fill(Tokens.Colors.systemAccent).padding(6)
                            .shadow(color: Tokens.Colors.systemAccent, radius: 8, y: 6))
                } else {
                    shape.fill(hovering && isEnabled ? Tokens.Colors.rowHover : Tokens.Colors.tile)
                }
            }
            .brightness(primary && hovering && isEnabled ? 0.04 : 0)
            .contentShape(shape)
            // Dimmed as one piece: the glow never shows through a disabled button.
            .compositingGroup()
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.12)), value: configuration.isPressed)
            .animation(.plainEase(0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// 38 × 22, `success` when on, a white knob that springs across.
private struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(on ? Tokens.Colors.success : Tokens.Colors.tile)
                .overlay(Capsule().strokeBorder(Tokens.Colors.edge, lineWidth: 0.5))
                .frame(width: 38, height: 22)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                        .frame(width: 18, height: 18)
                        .offset(x: on ? 18 : 2)
                        .animation(Tokens.Motion.resolved(Tokens.Motion.spring(0.25)), value: on)
                }
                .animation(.plainEase(0.2), value: on)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private extension Animation {
    /// The standard `ease` curve, for small fades and fills.
    static func plainEase(_ duration: Double) -> Animation { .timingCurve(0.25, 0.1, 0.25, 1, duration: duration) }
    /// easeOutCubic: how the import's figures move to each new value.
    static func easeOutCubic(_ duration: Double) -> Animation { .timingCurve(0.215, 0.61, 0.355, 1, duration: duration) }
}
