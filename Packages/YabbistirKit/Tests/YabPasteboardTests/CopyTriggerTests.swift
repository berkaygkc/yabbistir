import CoreGraphics
import Foundation
import Testing
import YabCore
@testable import YabPasteboard

/// A poster that runs `effect` each time it posts (e.g. the target app copying).
final class BumpingPoster: KeystrokePosting {
    var posts: [(PasteKeystroke, CGKeyCode)] = []
    private let effect: () -> Void
    init(_ effect: @escaping () -> Void) { self.effect = effect }
    func post(_ keystroke: PasteKeystroke, keyCode: CGKeyCode) {
        posts.append((keystroke, keyCode))
        effect()
    }
}

@MainActor @Suite struct CopyTriggerTests {
    let cKey = KeyCodeResolver { $0 == 8 ? "c" : nil }

    @Test func copyWaitsForThePasteboardToChange() async {
        let board = FakePasteboard()
        let poster = BumpingPoster { board.changeCount += 1 }
        let trigger = CopyTrigger(reader: board, resolver: cKey, poster: poster)
        #expect(await trigger.copy())
        #expect(poster.posts.map(\.0) == [.commandC])
        #expect(poster.posts.first?.1 == 8)
    }

    @Test func copyGivesUpAfterTheTimeout() async {
        let board = FakePasteboard()
        let start = ContinuousClock.now
        let trigger = CopyTrigger(reader: board, resolver: cKey, poster: BumpingPoster {})
        #expect(await trigger.copy() == false)
        #expect(ContinuousClock.now - start >= .milliseconds(300))
    }
}
