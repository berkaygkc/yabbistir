/// Where the panel opens: at the text cursor (falling back to the mouse pointer) or always at the pointer.
public enum PanelPosition: String, CaseIterable, Sendable {
    case caret, pointer
}
