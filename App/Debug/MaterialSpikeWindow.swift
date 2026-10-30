#if DEBUG
import AppKit
import SwiftUI
import YabUI

/// Side-by-side comparison of the two panel materials over the real desktop,
/// so one can be picked. Debug builds only.
@MainActor
final class MaterialSpikeWindow {
    private var window: ComparisonPanel?

    func show(env: AppEnvironment) {
        let models = PanelMaterial.allCases.map { _ in
            PanelViewModel(library: env.library, language: env.language)
        }
        for model in models {
            model.reset()
            model.isPresented = true
        }
        let titles = ["A — Liquid Glass", "B — Prototip camı"]
        let content = HStack(alignment: .top, spacing: 48) {
            ForEach(0..<PanelMaterial.allCases.count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 14) {
                    Text(titles[index])
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                    PanelView(model: models[index], material: PanelMaterial.allCases[index])
                }
            }
        }
        .padding(48)

        let panel = ComparisonPanel()
        panel.contentView = NSHostingView(rootView: content)
        let size = panel.contentView!.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}

/// Transparent, key-capable panel that closes on Esc.
private final class ComparisonPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
#endif
