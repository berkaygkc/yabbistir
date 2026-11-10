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

    /// ⌘K's "All transforms" row names the key that opens the ⇧ panel, as the footer does: ⇧ on a plain layout, ⌘T while
    /// an input method has the ⇧ tap. The other rows keep their keys.
    @MainActor @Test func allTransformsFollowsTheInputMethod() {
        #expect(ActionMenuView.keys(.allTransforms, shiftReturn: nil, inputMethod: false) == ["⇧"])
        #expect(ActionMenuView.keys(.allTransforms, shiftReturn: nil, inputMethod: true) == ["⌘", "T"])
        #expect(ActionMenuView.keys(.copy, shiftReturn: nil, inputMethod: true) == ["⌘", "C"])
        #expect(ActionMenuView.keys(.paste, shiftReturn: nil, inputMethod: true) == ["↵"])
        #expect(ActionMenuView.keys(.pastePlain, shiftReturn: .pastePlain, inputMethod: true) == ["⇧", "↵"])
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
