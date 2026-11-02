import Foundation
import Testing
@testable import YabCore
@testable import YabStack

/// ⌘⇧C copied nothing: a copy the same app made on its own a moment before is what the person meant.
@Suite struct RecentCopyTests {
    static let pressedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let terminal = "com.apple.Terminal"

    func copy(from app: String?, secondsBefore: Double, device: DeviceKind = .local, id: Int64 = 7) -> ClipItem {
        let at = Self.pressedAt.addingTimeInterval(-secondsBefore)
        return ClipItem(id: id, kind: .text, previewText: "seçili metin", searchText: "secili metin", contentHash: "h\(id)",
                        sourceBundleID: app, sourceName: nil, device: device, firstCopiedAt: at, lastCopiedAt: at, lastUsedAt: at)
    }

    @Test func aCopyTheSameAppMadeAMomentAgoIsMeant() {
        #expect(RecentCopy.meant(copy(from: Self.terminal, secondsBefore: 1.2), frontApp: Self.terminal, pressedAt: Self.pressedAt) == 7)
        #expect(RecentCopy.meant(copy(from: Self.terminal, secondsBefore: 3), frontApp: Self.terminal, pressedAt: Self.pressedAt) == 7)
    }

    /// A copy-on-select can reach the clipboard a beat after the press.
    @Test func aCopyJustAfterThePressIsMeant() {
        #expect(RecentCopy.meant(copy(from: Self.terminal, secondsBefore: -0.4), frontApp: Self.terminal, pressedAt: Self.pressedAt) == 7)
    }

    @Test func anOlderCopyIsNot() {
        #expect(RecentCopy.meant(copy(from: Self.terminal, secondsBefore: 3.1), frontApp: Self.terminal, pressedAt: Self.pressedAt) == nil)
    }

    @Test func aCopyFromAnotherAppIsNot() {
        #expect(RecentCopy.meant(copy(from: "com.apple.Safari", secondsBefore: 1), frontApp: Self.terminal, pressedAt: Self.pressedAt) == nil)
        #expect(RecentCopy.meant(copy(from: nil, secondsBefore: 1), frontApp: Self.terminal, pressedAt: Self.pressedAt) == nil)
        #expect(RecentCopy.meant(copy(from: Self.terminal, secondsBefore: 1), frontApp: nil, pressedAt: Self.pressedAt) == nil)
    }

    /// A copy from the iPhone (Universal Clipboard) was not made by the app in front.
    @Test func aCopyFromAnotherDeviceIsNot() {
        #expect(RecentCopy.meant(copy(from: Self.terminal, secondsBefore: 1, device: .remote), frontApp: Self.terminal,
                                 pressedAt: Self.pressedAt) == nil)
    }

    @Test func noCopyNoGuess() {
        #expect(RecentCopy.meant(nil, frontApp: Self.terminal, pressedAt: Self.pressedAt) == nil)
    }
}
