import Carbon
import CoreGraphics
import Foundation

/// Finds the physical key that types a character on the current layout, so the
/// synthesized ⌘V works on Turkish F, Dvorak, AZERTY and friends.
public struct KeyCodeResolver: Sendable {
    private let translate: @Sendable (CGKeyCode) -> String?

    public init(translate: @escaping @Sendable (CGKeyCode) -> String?) {
        self.translate = translate
    }

    public func keyCode(for character: Character) -> CGKeyCode? {
        let target = String(character).lowercased()
        return (0..<128).map(CGKeyCode.init).first { translate($0)?.lowercased() == target }
    }

    /// Uses the ASCII-capable layout macOS itself uses to resolve ⌘-shortcuts.
    public static func currentASCIICapable() -> KeyCodeResolver {
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return KeyCodeResolver { _ in nil }
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return KeyCodeResolver { keyCode in
            layoutData.withUnsafeBytes { raw -> String? in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                                            characters.count, &length, &characters)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }
}
