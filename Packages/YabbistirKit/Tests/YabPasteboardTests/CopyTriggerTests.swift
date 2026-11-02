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

/// The keys held down (⇧, ⌥ or ⌃) as the trigger sees them: held for the first `heldChecks` looks.
@MainActor final class HeldKeys {
    var heldChecks: Int
    private(set) var checks = 0
    init(heldChecks: Int) { self.heldChecks = heldChecks }
    func held() -> Bool {
        checks += 1
        return checks <= heldChecks
    }
}

@MainActor @Suite struct CopyTriggerTests {
    let cKey = KeyCodeResolver { $0 == 8 ? "c" : nil }

    @Test func copyWaitsForThePasteboardToChange() async {
        let board = FakePasteboard()
        let poster = BumpingPoster { board.changeCount += 1 }
        let trigger = CopyTrigger(reader: board, resolver: cKey, poster: poster, keysHeld: { false })
        #expect(await trigger.copy())
        #expect(poster.posts.map(\.0) == [.commandC])
        #expect(poster.posts.first?.1 == 8)
    }

    @Test func copyGivesUpAfterTheTimeout() async {
        let board = FakePasteboard()
        let start = ContinuousClock.now
        let trigger = CopyTrigger(reader: board, resolver: cKey, poster: BumpingPoster {}, keysHeld: { false })
        #expect(await trigger.copy() == false)
        #expect(ContinuousClock.now - start >= .milliseconds(300))
    }

    /// ⌘⇧C fires as C comes up, ⇧ often still down: ⌘C goes once the keys are up, so Terminal takes it as Copy.
    @Test func copyWaitsForHeldKeysToComeUp() async {
        let board = FakePasteboard()
        let keys = HeldKeys(heldChecks: 3)
        var checksAtPost: Int?
        let poster = BumpingPoster {
            checksAtPost = keys.checks
            board.changeCount += 1
        }
        let trigger = CopyTrigger(reader: board, resolver: cKey, poster: poster, keysHeld: keys.held)
        #expect(await trigger.copy())
        #expect(checksAtPost == 4, "three looks found the keys down, the fourth found them up")
        #expect(poster.posts.count == 1)
    }

    /// Keys held on and on never keep the copy from happening: after the wait, ⌘C goes anyway.
    @Test func keysHeldTooLongStillCopy() async {
        let board = FakePasteboard()
        let start = ContinuousClock.now
        let poster = BumpingPoster { board.changeCount += 1 }
        let trigger = CopyTrigger(reader: board, resolver: cKey, poster: poster, keysHeld: { true }, keyWait: .milliseconds(60))
        #expect(await trigger.copy())
        #expect(poster.posts.count == 1)
        #expect(ContinuousClock.now - start >= .milliseconds(60))
    }
}
