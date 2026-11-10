import CoreGraphics

/// The keyboard owns the selection until the pointer moves. A list that scrolls or changes under a resting pointer
/// brings a row under it that the person never pointed at; that row's hover is ignored until the pointer moves.
public struct HoverGate: Sendable {
    /// Where the pointer rested when the keyboard last acted; nil while the pointer leads.
    private var keyboardAt: CGPoint?

    public init() {}

    /// A key moved a selection, scrolled a list or changed its rows, with the pointer at `pointer`.
    public mutating func keyboardActed(pointer: CGPoint) {
        keyboardAt = pointer
    }

    /// Whether a hover now, with the pointer at `pointer`, may select its row: always while the pointer leads; after
    /// the keyboard, only once the pointer has moved, which gives it the lead back.
    public mutating func accepts(pointer: CGPoint) -> Bool {
        guard let keyboardAt else { return true }
        guard pointer != keyboardAt else { return false }
        self.keyboardAt = nil
        return true
    }
}
