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
}
