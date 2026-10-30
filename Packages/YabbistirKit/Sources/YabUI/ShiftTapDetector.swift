import AppKit

/// A bare ⇧ tap: pressed and released within 450 ms with no key and no other modifier in
/// between, so ⇧↵, capitals and ⇧⌘ shortcuts never count.
public struct ShiftTapDetector: Sendable {
    public static let limit: TimeInterval = 0.45
    private var pressedAt: TimeInterval?
    /// Another modifier or a key joined in; nothing counts until every modifier is up again.
    private var spoiled = false

    public init() {}

    /// From a flagsChanged event; true when this change ends a tap.
    public mutating func flagsChanged(_ flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Bool {
        let held = flags.intersection([.shift, .command, .control, .option])
        guard !held.isEmpty else {
            defer { (pressedAt, spoiled) = (nil, false) }
            guard let pressedAt, !spoiled else { return false }
            return time - pressedAt <= Self.limit
        }
        if held == .shift, pressedAt == nil, !spoiled { pressedAt = time }
        if held != .shift { spoiled = true }
        return false
    }

    /// A key went down: a ⇧ being held is no longer a tap.
    public mutating func keyDown() {
        if pressedAt != nil { spoiled = true }
    }
}
