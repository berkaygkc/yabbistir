import AppKit
import Testing
@testable import YabUI

/// The first-run window's keys: Return and keypad Enter press the primary button, Esc finishes. A held key never
/// repeats its action, so holding Return can't run through the steps.
@Suite struct OnboardingKeyTests {
    @Test func returnAndEnterPressThePrimary() {
        #expect(OnboardingKey.action(keyCode: 36, isRepeat: false) == .primary)
        #expect(OnboardingKey.action(keyCode: 76, isRepeat: false) == .primary)
    }

    @Test func escapeFinishes() {
        #expect(OnboardingKey.action(keyCode: 53, isRepeat: false) == .escape)
    }

    @Test func aHeldKeyDoesNothingMore() {
        for keyCode: UInt16 in [36, 76, 53] {
            #expect(OnboardingKey.action(keyCode: keyCode, isRepeat: true) == nil)
        }
    }

    @Test func otherKeysAndModifiedKeysPassThrough() {
        for keyCode: UInt16 in [0, 48, 49, 125, 126] {
            #expect(OnboardingKey.action(keyCode: keyCode, isRepeat: false) == nil)
        }
        #expect(OnboardingKey.action(keyCode: 36, isRepeat: false, modifiers: .command) == nil)
        #expect(OnboardingKey.action(keyCode: 53, isRepeat: false, modifiers: .option) == nil)
        // Caps Lock or a function-key flag doesn't make Return another key.
        #expect(OnboardingKey.action(keyCode: 36, isRepeat: false, modifiers: .capsLock) == .primary)
    }
}
