import SwiftUI
import YabLocalization

/// The 42 pt footer: "Paste ↵ | (Transform ⇧ |) Actions ⌘K" at the right, Transform ⌘T under an input method; on a
/// source's row its own actions ("Şifreyi yapıştır ↵ | Kullanıcı adı ⇧↵ | Eylemler ⌘K"), on the locked row "Komutu
/// kopyala ⌘C" alone. While ⌘ is held it cross-fades (5 pt vertical slide) to the ⌘ shortcuts; while ⇧ is held, to one
/// button saying what ⇧↵ does. One layer shows at a time, and a new kind of row slides its actions in from below.
/// Nothing in it ever wraps.
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
                rowActions
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

    /// An item's actions or a source row's, each kind its own: a change of kind fades the new one in from 5 pt below
    /// as the old leaves upwards, as a held key's layer does.
    private var rowActions: some View {
        let source = model.sourceBar
        return ZStack(alignment: .trailing) {
            if let source {
                sourceActions(source)
                    .id(source)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)), removal: .opacity.combined(with: .offset(y: -5))))
            } else {
                actions
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)), removal: .opacity.combined(with: .offset(y: -5))))
            }
        }
        .animation(Tokens.Motion.resolved(Tokens.Motion.ease(0.18)), value: source)
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
                        // Under an input method a ⇧ tap is the method's: ⌘T opens the panel instead.
                        if model.inputMethodActive {
                            HStack(spacing: 3) { Keycap("⌘"); Keycap("T") }
                        } else {
                            Keycap("⇧")
                        }
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

    /// A source's row: ↵ its first action, ⇧↵ its second's short name, then "Eylemler ⌘K"; the locked row: "Komutu
    /// kopyala ⌘C" alone ("Eylemler ⌘K" without a command). The first button is the primary one.
    private func sourceActions(_ bar: SourceBar) -> some View {
        HStack(spacing: 4) {
            if let primary = bar.primary {
                barButton(primary, primary: true) {
                    if let id = model.selectedID { onPaste(id) }
                }
            }
            if let alternate = bar.alternate {
                divider
                barButton(alternate, primary: false) {
                    if let id = model.selectedID, let action = model.shiftReturnAction(rowID: id) { onAction(action) }
                }
            }
            if bar.showsActions {
                if bar.primary != nil { divider }
                barButton(BarLabel(title: L10n.string("panel.footer.actions", model.language), keys: ["⌘", "K"]), primary: false) {
                    _ = model.handle(.toggleActions)
                }
            }
        }
    }

    /// One of the bar's buttons: the primary in the text colour, the others quieter.
    private func barButton(_ label: BarLabel, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(label.title).font(primary ? Tokens.Fonts.labelStrong : Tokens.Fonts.labelStrong.weight(.medium))
                    .lineLimit(1).fixedSize()
                HStack(spacing: 3) { ForEach(label.keys, id: \.self) { Keycap($0) } }
            }
            .foregroundStyle(primary ? Tokens.Colors.text : Tokens.Colors.textSecondary)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(ActionButtonStyle())
    }

    private var divider: some View {
        Rectangle().fill(Tokens.Colors.hairline).frame(width: 1, height: 16)
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

    /// All three ⌘ hints when they fit; otherwise the "Add to category" hint steps aside. A source's row has its own:
    /// "⌘1–9 Şifreyi yapıştır · ⌘C Kullanıcı adını kopyala · ⌘K Eylemler", the middle one stepping aside the same way.
    @ViewBuilder private var commandHints: some View {
        if let hints = model.sourceCommandHints {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { ForEach(Array(hints.enumerated()), id: \.offset) { hint($0.element) } }
                HStack(spacing: 14) {
                    ForEach(Array((hints.count > 2 ? [hints[0], hints[hints.count - 1]] : hints).enumerated()), id: \.offset) { hint($0.element) }
                }
            }
            .padding(.trailing, 6)
        } else {
            itemCommandHints
        }
    }

    private var itemCommandHints: some View {
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
        hint(BarLabel(title: L10n.string(key, model.language), keys: keys))
    }

    private func hint(_ label: BarLabel) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) { ForEach(label.keys, id: \.self) { Keycap($0) } }
            Text(label.title).font(Tokens.Fonts.label).lineLimit(1).fixedSize()
        }
        .foregroundStyle(Tokens.Colors.textSecondary)
    }
}
