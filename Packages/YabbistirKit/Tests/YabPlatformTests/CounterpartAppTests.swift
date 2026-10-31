import Foundation
import Testing
@testable import YabPlatform

@Suite struct CounterpartAppTests {
    let release = CounterpartApp.releaseID, debug = CounterpartApp.debugID
    let start = Date(timeIntervalSinceReferenceDate: 815_000_000)

    /// A copy of `bundleID` launched `seconds` after `start` (nil: launch services does not know when).
    func copy(_ bundleID: String, at seconds: Double?, pid: Int32) -> RunningCopy {
        RunningCopy(bundleID: bundleID, launchDate: seconds.map { start.addingTimeInterval($0) }, processID: pid)
    }

    @Test func releaseAndDebugPointAtEachOther() {
        #expect(CounterpartApp.counterpart(of: "dev.yabbistir.app") == "dev.yabbistir.app.debug")
        #expect(CounterpartApp.counterpart(of: "dev.yabbistir.app.debug") == "dev.yabbistir.app")
    }

    @Test func unknownIDsHaveNone() {
        #expect(CounterpartApp.counterpart(of: "dev.yabbistir.extension-host") == nil)
        #expect(CounterpartApp.counterpart(of: "com.apple.finder") == nil)
        #expect(CounterpartApp.counterpart(of: "") == nil)
    }

    @Test func quitsWhenALaterCounterpartAppears() {
        let finder = copy("com.apple.finder", at: 20, pid: 900)
        #expect(CounterpartApp.shouldQuit(own: copy(release, at: 0, pid: 100), added: [finder, copy(debug, at: 20, pid: 901)]))
        #expect(CounterpartApp.shouldQuit(own: copy(debug, at: 0, pid: 100), added: [copy(release, at: 20, pid: 901)]))
    }

    @Test func staysWhenNoCounterpartAppears() {
        let own = copy(release, at: 0, pid: 100)
        #expect(!CounterpartApp.shouldQuit(own: own, added: []))
        #expect(!CounterpartApp.shouldQuit(own: own, added: [copy(release, at: 20, pid: 901), copy("com.apple.finder", at: 20, pid: 902)]))
        #expect(!CounterpartApp.shouldQuit(own: copy("com.apple.finder", at: 0, pid: 100), added: [copy(release, at: 20, pid: 901)]))
    }

    /// As it starts, a copy asks only the other build's copies launched before it to quit.
    @Test func onlyAnEarlierCopyIsAskedToQuit() {
        let own = copy(release, at: 10, pid: 500)
        let earlier = copy(debug, at: 9, pid: 400), later = copy(debug, at: 10.4, pid: 600)
        #expect(CounterpartApp.copiesToReplace(own: own, running: [earlier, later]) == [earlier])
        #expect(CounterpartApp.copiesToReplace(own: own, running: [later]).isEmpty)
        #expect(CounterpartApp.copiesToReplace(own: copy("com.apple.finder", at: 10, pid: 500), running: [earlier]).isEmpty)
    }

    /// A running copy gives way only to the other build launched after it.
    @Test func yieldsOnlyToALaterLaunch() {
        let own = copy(release, at: 10, pid: 500)
        #expect(CounterpartApp.shouldQuit(own: own, added: [copy(debug, at: 10.4, pid: 600)]))
        #expect(!CounterpartApp.shouldQuit(own: own, added: [copy(debug, at: 9.6, pid: 400)]))
    }

    /// Both builds started within a second: each one asks at start and watches for the other, and exactly one quits.
    @Test(arguments: [0.0, 0.3, 1.0])
    func twoCopiesStartedTogetherNeverBothQuit(gap: Double) {
        let first = copy(release, at: 10, pid: 500), second = copy(debug, at: 10 + gap, pid: 501)
        let firstQuits = !CounterpartApp.copiesToReplace(own: second, running: [first]).isEmpty
            || CounterpartApp.shouldQuit(own: first, added: [second])
        let secondQuits = !CounterpartApp.copiesToReplace(own: first, running: [second]).isEmpty
            || CounterpartApp.shouldQuit(own: second, added: [first])
        #expect(firstQuits && !secondQuits)
    }

    /// Without a launch date (or with the same one) the process ID orders them: the later launch has the higher one.
    @Test func anUnknownLaunchDateFallsBackToTheProcessOrder() {
        let own = copy(release, at: nil, pid: 500)
        let older = copy(debug, at: 9, pid: 400), newer = copy(debug, at: 11, pid: 600)
        #expect(CounterpartApp.copiesToReplace(own: own, running: [older, newer]) == [older])
        #expect(CounterpartApp.shouldQuit(own: own, added: [newer]))
        #expect(!CounterpartApp.shouldQuit(own: own, added: [older]))
    }
}
