import SwiftUI
import YabCore
import YabLocalization

/// A 32 pt menu row: optional leading view, title, trailing view; the highlighted row is the
/// neutral selection grey, destructive rows are red.
struct MenuRow<Leading: View, Trailing: View>: View {
    let title: String
    var isHighlighted = false
    var isDestructive = false
    /// The title keeps its width and the trailing view shortens (the ⇧ panel's outputs).
    var keepsTitle = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            leading
            Text(title)
                .font(Tokens.Fonts.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(keepsTitle ? 1 : 0)
            Spacer(minLength: 8)
            trailing
        }
        .foregroundStyle(isDestructive ? Tokens.Colors.danger : Tokens.Colors.text)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(isHighlighted ? Tokens.Colors.selection : .clear,
                    in: RoundedRectangle(cornerRadius: Tokens.Metrics.menuRowRadius, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A glass menu surface: 12 pt radius, 6 pt padding.
struct MenuSurface<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(6)
            .frame(width: width)
            .background(PanelBackground(material: PanelMaterial.current, cornerRadius: Tokens.Metrics.menuRadius))
    }
}

struct MenuSeparator: View {
    /// Its 1 pt line and 5 pt above and below.
    static let height: CGFloat = 11

    var body: some View {
        Rectangle().fill(Tokens.Colors.hairline).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 5)
    }
}

/// "Kategoriler ⌄" at the right of the search row, led by the dots of the opened on-select categories, and a source's
/// key after them when one of those is a source's (in the button's own colour).
struct CategoryDropdown: View {
    @Bindable var model: PanelViewModel
    @State private var hovering = false

    var body: some View {
        Button {
            _ = model.handle(.toggleCategoryMenu)
        } label: {
            HStack(spacing: 6) {
                let dots = model.categoryButtonDots
                if !dots.isEmpty {
                    HStack(spacing: -3) {
                        ForEach(Array(dots.enumerated()), id: \.offset) { _, color in
                            Circle().fill(Tokens.Colors.category(color)).frame(width: 8, height: 8)
                                .overlay(Circle().strokeBorder(Tokens.Colors.surfaceSolid, lineWidth: 1))
                        }
                    }
                }
                if model.categoryButtonMarksSource { SourceMark(size: 10) }
                Text(L10n.string("panel.categories.button", model.language))
                    .font(Tokens.Fonts.labelStrong.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(hovering || model.layer == .categoryMenu ? Tokens.Colors.text : Tokens.Colors.textSecondary)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 30)
            .background(Tokens.Colors.keycapFill, in: RoundedRectangle(cornerRadius: Tokens.Metrics.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The Kategoriler menu (264 pt): "on select" categories with a check when open as a column (a source's led by its key
/// in the dot's place), then "Edit categories ⌘E".
struct CategoryMenuView: View {
    @Bindable var model: PanelViewModel
    let onAction: (PanelAction) -> Void

    var body: some View {
        MenuSurface(width: 264) {
            Text(L10n.string("menu.categories.title", model.language))
                .font(Tokens.Fonts.section)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            ForEach(Array(model.categoryMenu.enumerated()), id: \.offset) { index, option in
                switch option {
                case .category(let category, let isShown):
                    MenuRow(title: category.name, isHighlighted: index == model.menuSelection) {
                        if category.isSource {
                            // In the dot's slot, so its name lines up with the others'.
                            SourceMark(size: 12).foregroundStyle(Tokens.Colors.textSecondary).frame(width: 9, height: 9)
                        } else {
                            Circle().fill(Tokens.Colors.category(category.color)).frame(width: 9, height: 9)
                        }
                    } trailing: {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).opacity(isShown ? 1 : 0)
                    }
                    .onHover { if $0, model.acceptsHover() { model.highlightMenuRow(index) } }
                    .onTapGesture { if let action = model.activateMenuRow(index) { onAction(action) } }
                case .editCategories:
                    if index > 0 { MenuSeparator() }
                    MenuRow(title: L10n.string("menu.categories.edit", model.language), isHighlighted: index == model.menuSelection) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 13)).foregroundStyle(Tokens.Colors.textSecondary)
                    } trailing: {
                        HStack(spacing: 3) { Keycap("⌘"); Keycap("E") }
                    }
                    .onHover { if $0, model.acceptsHover() { model.highlightMenuRow(index) } }
                    .onTapGesture { if let action = model.activateMenuRow(index) { onAction(action) } }
                }
            }
        }
    }
}

/// The search line at the foot of a ⌘K menu: the query and a caret, or "Search actions…".
struct ActionSearchLine: View {
    /// 6 pt above its hairline, the hairline, and the 36 pt line.
    static let height: CGFloat = 42.5

    let query: String
    let language: AppLanguage

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5).padding(.top, 6)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Tokens.Colors.textSecondary)
                HStack(spacing: 0) {
                    Text(query).font(Tokens.Fonts.body).foregroundStyle(Tokens.Colors.text)
                    BlinkingCaret().scaleEffect(0.75, anchor: .leading)
                    if query.isEmpty {
                        Text(L10n.string("actions.search", language)).font(Tokens.Fonts.body)
                            .foregroundStyle(Tokens.Colors.textSecondary).padding(.leading, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
        }
    }
}

/// ⌘K (300 pt): every action on the selected item, grouped by hairlines, with its shortcut; a
/// search line sits at the bottom. On a source's row, its own actions (a key for a secret), then Preview and
/// Edit categories. Taller than `maxHeight` (the panel's room above its action bar), its rows scroll above the search
/// line, and the keyboard's highlight stays in view.
struct ActionMenuView: View {
    /// The menu's padding and its search line, what is not its rows, rounded up to a whole point (the hairline's half
    /// point), so a menu fitted to its room never overshoots it.
    static let chrome: CGFloat = (2 * 6 + ActionSearchLine.height).rounded(.up)

    @Bindable var model: PanelViewModel
    var maxHeight: CGFloat = .infinity
    let onAction: (PanelAction) -> Void

    var body: some View {
        MenuSurface(width: 300) {
            let items = model.actionItems
            let fit = listFit(items)
            if items.isEmpty {
                MenuRow(title: L10n.string("actions.none", model.language)) { EmptyView() } trailing: { EmptyView() }
                    .foregroundStyle(Tokens.Colors.textSecondary)
            }
            if fit.scrolls {
                scrollingRows(items, height: fit.height)
            } else {
                rows(items)
            }
            ActionSearchLine(query: model.actionQuery, language: model.language)
        }
    }

    /// Rows of 32 pt and an 11 pt separator between groups, against the room the search line and padding leave.
    func listFit(_ items: [PanelActionItem]) -> TransformListLayout.Fit {
        let separators = items.indices.dropFirst().filter { group(of: items[$0 - 1]) != group(of: items[$0]) }.count
        return TransformListLayout.fit(rows: items.count, sections: separators, sectionHeight: MenuSeparator.height,
                                       available: maxHeight - Self.chrome)
    }

    /// Each row under the separator that opens its group, if any: one piece, so a group's first row brings its line.
    private func rows(_ items: [PanelActionItem]) -> some View {
        let shiftReturn = model.shiftReturnItem
        return ForEach(Array(items.enumerated()), id: \.element) { index, item in
            VStack(alignment: .leading, spacing: 0) {
                if index > 0, group(of: items[index - 1]) != group(of: item) { MenuSeparator() }
                MenuRow(title: model.actionLabel(item), isHighlighted: index == model.menuSelection, isDestructive: item == .delete) {
                    if case .transform(let id) = item, let command = model.transformCommand(id) {
                        CommandIcon(icon: command.icon).frame(width: 16)
                    } else if model.sourceAction(item)?.kind == .secret {
                        SourceMark(size: 13).frame(width: 16).foregroundStyle(Tokens.Colors.textSecondary)
                    } else {
                        Image(systemName: Self.symbol(item)).font(.system(size: 13)).frame(width: 16)
                            .foregroundStyle(item == .delete ? Tokens.Colors.danger : Tokens.Colors.textSecondary)
                    }
                } trailing: {
                    HStack(spacing: 3) { ForEach(Self.keys(item, shiftReturn: shiftReturn), id: \.self) { Keycap($0) } }
                }
                .onHover { if $0, model.acceptsHover() { model.highlightMenuRow(index) } }
                .onTapGesture { if let action = model.activateMenuRow(index) { onAction(action) } }
            }
            .id(item)
        }
    }

    /// The rows under a ghost scroller, cut clean at the menu's top and at the search line. ↑ ↓ and the search bring the
    /// highlighted row into view; pointing never scrolls.
    private func scrollingRows(_ items: [PanelActionItem], height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) { rows(items) }
                    .background(OverlayScrollerStyle())
            }
            .scrollIndicators(.automatic)
            .frame(height: height)
            .onAppear {
                // Laid out first: a scroll asked for before that is lost.
                guard items.indices.contains(model.menuSelection), model.menuSelection > 0 else { return }
                let item = items[model.menuSelection]
                DispatchQueue.main.async { proxy.scrollTo(item) }
            }
            .onChange(of: model.menuReveal) {
                let items = model.actionItems
                guard items.indices.contains(model.menuSelection) else { return }
                withAnimation(Tokens.Motion.resolved(Tokens.Motion.ease(0.2))) { proxy.scrollTo(items[model.menuSelection]) }
            }
        }
    }

    /// The paste target's own actions are a group of their own, above the paste actions.
    private func group(of item: PanelActionItem) -> Int {
        model.isForTarget(item) ? -1 : Self.group(of: item)
    }

    static func group(of item: PanelActionItem) -> Int {
        switch item {
        case .paste, .pastePlain, .copy, .addToStack, .sourcePrimary, .sourceAlternate, .sourceCopy, .copySourceCommand: 0
        case .transform, .allTransforms: 1
        case .addToCategory, .preview, .editCategories: 2
        case .delete: 3
        }
    }

    static func symbol(_ item: PanelActionItem) -> String {
        switch item {
        case .paste, .sourcePrimary, .sourceAlternate: "doc.on.clipboard"
        case .pastePlain: "textformat"
        case .copy, .sourceCopy, .copySourceCommand: "doc.on.doc"
        case .addToStack: "square.stack.3d.up"
        case .transform: "puzzlepiece.extension"
        case .allTransforms: "arrow.triangle.2.circlepath"
        case .addToCategory: "tag"
        case .preview: "eye"
        case .editCategories: "slider.horizontal.3"
        case .delete: "trash"
        }
    }

    /// ⇧↵ sits on the row it runs (`shiftReturn`), wherever that row is.
    static func keys(_ item: PanelActionItem, shiftReturn: PanelActionItem?) -> [String] {
        if item == shiftReturn { return ["⇧", "↵"] }
        return switch item {
        case .paste, .sourcePrimary: ["↵"]
        case .sourceAlternate: ["⇧", "↵"]
        case .copy, .sourceCopy, .copySourceCommand: ["⌘", "C"]
        case .pastePlain, .addToStack, .transform: []
        case .allTransforms: ["⇧"]
        case .addToCategory: ["⌘", "P"]
        case .preview: ["␣"]
        case .editCategories: ["⌘", "E"]
        case .delete: ["⌘", "⌫"]
        }
    }
}
