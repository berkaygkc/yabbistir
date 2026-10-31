import SwiftUI
import YabLocalization

/// The 42 pt footer: "Paste ↵ | (Transform ⇧ |) Actions ⌘K" at the right. While ⌘ is held it cross-fades
/// (5 pt vertical slide) to the ⌘ shortcuts; while ⇧ is held, to one button saying what ⇧↵ does. One
/// layer shows at a time. Nothing in it ever wraps.
struct ActionBarView: View {
    @Bindable var model: PanelViewModel
    let onPaste: (Int64) -> Void
    /// The ⇧↵ button's action.
    let onAction: (PanelAction) -> Void

    private enum Layer {
        case actions, shiftReturn, commands
    }

    /// Held ⌘ belongs to what has the keyboard: the ⇧ panel turns its own footer instead.
    private var layer: Layer {
        if model.showsIndexKeys, model.layer != .transforms { return .commands }
        return model.showsShiftHint ? .shiftReturn : .actions
    }

    var body: some View {
        let layer = layer
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                actions
                    .opacity(layer == .actions ? 1 : 0)
                    .offset(y: layer == .actions ? 0 : -5)
                    .allowsHitTesting(layer == .actions)
                shiftReturn
                    .opacity(layer == .shiftReturn ? 1 : 0)
                    .offset(y: layer == .shiftReturn ? 0 : 5)
                    .allowsHitTesting(layer == .shiftReturn)
                commandHints
                    .opacity(layer == .commands ? 1 : 0)
                    .offset(y: layer == .commands ? 0 : 5)
            }
            .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.18)), value: layer)
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(height: Tokens.Metrics.footerHeight)
        .background(Tokens.Colors.footerTint)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.Colors.hairline).frame(height: 0.5) }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button {
                if let id = model.selectedID { onPaste(id) }
            } label: {
                HStack(spacing: 9) {
                    Text(L10n.string("panel.footer.paste", model.language)).font(Tokens.Fonts.labelStrong)
                        .lineLimit(1).fixedSize()
                    Keycap("↵")
                }
                .foregroundStyle(Tokens.Colors.text)
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(ActionButtonStyle())
            Rectangle().fill(Tokens.Colors.hairline).frame(width: 1, height: 16)
            if model.selectedTransformCount > 0 {
                Button {
                    _ = model.handle(.toggleTransforms)
                } label: {
                    HStack(spacing: 9) {
                        Text(L10n.string("panel.footer.transform", model.language)).font(Tokens.Fonts.labelStrong.weight(.medium))
                            .lineLimit(1).fixedSize()
                        Keycap("⇧")
                    }
                    .foregroundStyle(model.layer == .transforms ? Tokens.Colors.text : Tokens.Colors.textSecondary)
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ActionButtonStyle())
                .transition(.opacity)
                Rectangle().fill(Tokens.Colors.hairline).frame(width: 1, height: 16)
            }
            Button {
                _ = model.handle(.toggleActions)
            } label: {
                HStack(spacing: 9) {
                    Text(L10n.string("panel.footer.actions", model.language)).font(Tokens.Fonts.labelStrong.weight(.medium))
                        .lineLimit(1).fixedSize()
                    HStack(spacing: 3) { Keycap("⌘"); Keycap("K") }
                }
                .foregroundStyle(Tokens.Colors.textSecondary)
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(ActionButtonStyle())
        }
    }

    /// What ⇧↵ does, as the primary button in place of the actions ("Düz metin olarak yapıştır ⇧↵").
    private var shiftReturn: some View {
        Button {
            if let action = model.handle(.confirm(plain: true)) { onAction(action) }
        } label: {
            HStack(spacing: 9) {
                Text(model.shiftHintLabel ?? "").font(Tokens.Fonts.labelStrong)
                    .lineLimit(1)
                HStack(spacing: 3) { Keycap("⇧"); Keycap("↵") }
            }
            .foregroundStyle(Tokens.Colors.text)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(ActionButtonStyle())
    }

    /// All three ⌘ hints when they fit; otherwise the "Add to category" hint steps aside.
    private var commandHints: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                hint(["⌘", "1–9"], "panel.footer.paste")
                hint(["⌘", "P"], "panel.footer.addToCategory")
                hint(["⌘", "K"], "panel.footer.actions")
            }
            HStack(spacing: 14) {
                hint(["⌘", "1–9"], "panel.footer.paste")
                hint(["⌘", "K"], "panel.footer.actions")
            }
        }
        .padding(.trailing, 6)
    }

    private func hint(_ keys: [String], _ key: String) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap($0) } }
            Text(L10n.string(key, model.language)).font(Tokens.Fonts.label).lineLimit(1).fixedSize()
        }
        .foregroundStyle(Tokens.Colors.textSecondary)
    }
}
