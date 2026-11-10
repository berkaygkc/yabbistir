import SwiftUI
import YabCore
import YabLocalization

/// ⌘P (264 pt): a search line, then the person's category rows with a check for the ones the item is in (a source's
/// category is its extension's to fill, so it is not listed), and "New category: …" when the query names none.
public struct PinPopoverView: View {
    @Bindable var model: PanelViewModel

    public init(model: PanelViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tag").font(.system(size: 12)).foregroundStyle(Tokens.Colors.textSecondary)
                HStack(spacing: 0) {
                    Text(model.pinQuery).font(Tokens.Fonts.body).foregroundStyle(Tokens.Colors.text)
                    BlinkingCaret().scaleEffect(0.75, anchor: .leading)
                    if model.pinQuery.isEmpty {
                        Text(L10n.string("pin.search", model.language)).font(Tokens.Fonts.body)
                            .foregroundStyle(Tokens.Colors.textSecondary).padding(.leading, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5).padding(.bottom, 4)
            ForEach(Array(model.pinOptions.enumerated()), id: \.offset) { index, option in
                row(option, index: index)
                    .onHover { if $0, model.acceptsHover() { model.highlightMenuRow(index) } }
                    .onTapGesture { _ = model.activateMenuRow(index) }
            }
        }
        .padding(6)
        .frame(width: 264)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelBackground(material: PanelMaterial.current, cornerRadius: Tokens.Metrics.panelRadius))
        .environment(\.locale, model.language.locale)
    }

    @ViewBuilder private func row(_ option: PinOption, index: Int) -> some View {
        switch option {
        case .category(let category, let isMember):
            MenuRow(title: category.name, isHighlighted: index == model.menuSelection) {
                Circle().fill(Tokens.Colors.category(category.color)).frame(width: 9, height: 9)
            } trailing: {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).opacity(isMember ? 1 : 0)
            }
        case .create(let name):
            MenuRow(title: L10n.string("pin.new", model.language, name), isHighlighted: index == model.menuSelection) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.Colors.textSecondary)
            } trailing: {
                EmptyView()
            }
        }
    }
}

/// Carries the focused column's selected row frame up to the panel.
struct SelectedRowFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}
