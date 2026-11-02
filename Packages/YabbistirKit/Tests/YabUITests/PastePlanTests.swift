import Testing
@testable import YabUI

@Suite struct PastePlanTests {
    @Test func everyCombination() {
        #expect(PastePlan.resolve(destination: .app, alwaysPlain: false, requestedPlain: false)
            == PastePlan(copyOnly: false, plainText: false))
        #expect(PastePlan.resolve(destination: .app, alwaysPlain: true, requestedPlain: false)
            == PastePlan(copyOnly: false, plainText: true))
        #expect(PastePlan.resolve(destination: .clipboard, alwaysPlain: false, requestedPlain: true)
            == PastePlan(copyOnly: true, plainText: true))
        #expect(PastePlan.resolve(destination: .clipboard, alwaysPlain: false, requestedPlain: false)
            == PastePlan(copyOnly: true, plainText: false))
    }
}
