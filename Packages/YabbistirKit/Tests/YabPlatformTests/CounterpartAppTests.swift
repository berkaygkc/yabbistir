import Testing
@testable import YabPlatform

@Suite struct CounterpartAppTests {
    @Test func releaseAndDebugPointAtEachOther() {
        #expect(CounterpartApp.counterpart(of: "dev.yabbistir.app") == "dev.yabbistir.app.debug")
        #expect(CounterpartApp.counterpart(of: "dev.yabbistir.app.debug") == "dev.yabbistir.app")
    }

    @Test func unknownIDsHaveNone() {
        #expect(CounterpartApp.counterpart(of: "dev.yabbistir.extension-host") == nil)
        #expect(CounterpartApp.counterpart(of: "com.apple.finder") == nil)
        #expect(CounterpartApp.counterpart(of: "") == nil)
    }

    @Test func quitsWhenTheCounterpartAppears() {
        #expect(CounterpartApp.shouldQuit(ownID: "dev.yabbistir.app", added: ["com.apple.finder", "dev.yabbistir.app.debug"]))
        #expect(CounterpartApp.shouldQuit(ownID: "dev.yabbistir.app.debug", added: ["dev.yabbistir.app"]))
    }

    @Test func staysWhenNoCounterpartAppears() {
        #expect(!CounterpartApp.shouldQuit(ownID: "dev.yabbistir.app", added: []))
        #expect(!CounterpartApp.shouldQuit(ownID: "dev.yabbistir.app", added: ["dev.yabbistir.app", "com.apple.finder"]))
        #expect(!CounterpartApp.shouldQuit(ownID: "com.apple.finder", added: ["dev.yabbistir.app"]))
    }
}
