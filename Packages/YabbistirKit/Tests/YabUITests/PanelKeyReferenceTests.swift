import Testing
import YabLocalization
@testable import YabUI

@Suite struct PanelKeyReferenceTests {
    /// ⌘T opens the ⇧ panel for everyone, and under an input method it is the only key that does.
    @Test func transformsListBothKeys() {
        let keys = PanelKeyReference.all.filter { $0.titleKey == "settings.keys.transforms" }.map(\.keys)
        #expect(keys == [["⇧"], ["⌘", "T"]])
        #expect(Set(PanelKeyReference.all.map(\.id)).count == PanelKeyReference.all.count)
    }

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
