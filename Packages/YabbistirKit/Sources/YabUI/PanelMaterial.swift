import AppKit
import SwiftUI

/// The two surfaces a floating panel can use. `current` holds the one the app uses, Liquid Glass;
/// `tunedEffect`, a blur under a tinted fill, is what the snapshot tests render.
public enum PanelMaterial: String, CaseIterable, Sendable {
    case liquidGlass
    case tunedEffect

    @MainActor public static var current: PanelMaterial = .liquidGlass
}

/// Background for floating surfaces: the chosen material, the glass rim and a 0.5 pt edge.
/// Reduce Transparency always falls back to the opaque surface color.
public struct PanelBackground: View {
    let material: PanelMaterial
    let cornerRadius: CGFloat
    let forceSolid: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(material: PanelMaterial, cornerRadius: CGFloat = Tokens.Metrics.panelRadius, forceSolid: Bool = false) {
        self.material = material
        self.cornerRadius = cornerRadius
        self.forceSolid = forceSolid
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if reduceTransparency || forceSolid {
                shape.fill(Tokens.Colors.surfaceSolid)
            } else {
                switch material {
                case .liquidGlass:
                    Color.clear.glassEffect(.regular, in: shape)
                case .tunedEffect:
                    VisualEffectBlur().clipShape(shape)
                    shape.fill(Tokens.Colors.surface)
                }
            }
        }
        .overlay(shape.strokeBorder(Tokens.Colors.edge, lineWidth: 0.5))
        .overlay(
            shape.strokeBorder(
                LinearGradient(stops: [.init(color: Tokens.Colors.rimTop, location: 0),
                                       .init(color: Tokens.Colors.rimBody, location: 0.4),
                                       .init(color: Tokens.Colors.rimBody, location: 1)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1))
    }
}

/// Behind-window blur (NSVisualEffectView), tinted above by the surface color.
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
