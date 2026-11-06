import Carbon

/// The keyboard's current input source, as Text Input Sources reports it.
enum InputSource {
    /// True for an input method (Pinyin, Kana, Hangul…: a mode of one, or one without modes), false for a plain layout
    /// (ABC, Turkish Q…).
    static func isInputMethod() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue()
        return CFEqual(type, kTISTypeKeyboardInputMode) || CFEqual(type, kTISTypeKeyboardInputMethodWithoutModes)
    }
}
