import Testing
import YabLocalization
@testable import YabUI

@Suite struct SettingsSectionTests {
    @Test func sectionsComeInTheSpecOrder() {
        #expect(SettingsSection.allCases == [
            .general, .shortcuts, .panel, .history, .categories, .extensions, .permissions, .import, .about,
        ])
    }

    @Test func everySectionTitleIsTranslated() {
        for section in SettingsSection.allCases {
            #expect(section.titleKey == "settings.section.\(section.rawValue)")
            for language in AppLanguage.allCases {
                let title = L10n.string(section.titleKey, language)
                #expect(title != section.titleKey, "\(section) has no \(language) title")
            }
        }
    }

    /// English and Turkish keep the 200 pt sidebar; a language whose longest title needs more gets it, within the column.
    @Test func theSidebarFitsTheLongestTitle() {
        #expect(SettingsSection.sidebarWidth(.english) == 200)
        #expect(SettingsSection.sidebarWidth(.turkish) == 200)
        #expect(SettingsSection.sidebarWidth(.japanese) > 200)
        #expect(SettingsSection.sidebarWidth(.german) > 200)
        for language in AppLanguage.allCases { #expect(SettingsSection.sidebarWidth(language) <= 260) }
    }
}
