import CoreGraphics

/// Where the panel opens: at the text cursor (falling back to the mouse pointer) or always at the pointer.
public enum PanelPosition: String, CaseIterable, Sendable {
    case caret, pointer
}

/// Picks the point the panel opens at.
public enum PanelAnchorChoice {
    /// An explicit anchor (a click on the menu bar icon) wins; otherwise the pointer, or the text caret
    /// with the pointer as its fallback.
    public static func anchor(position: PanelPosition, explicit: CGRect?, caret: () -> CGRect?,
                              pointer: () -> CGRect) -> CGRect {
        if let explicit { return explicit }
        switch position {
        case .pointer: return pointer()
        case .caret: return caret() ?? pointer()
        }
    }
}
