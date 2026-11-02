import Testing
import YabLocalization
@testable import YabUI

@Suite struct PanelKeyReferenceTests {
    @Test func everyRowIsTranslated() {
        #expect(!PanelKeyReference.all.isEmpty)
        for row in PanelKeyReference.all {
            #expect(!row.keys.isEmpty)
            for language in AppLanguage.allCases {
                #expect(L10n.string(row.titleKey, language) != row.titleKey, "\(row.titleKey) has no \(language) text")
            }
        }
    }
}
