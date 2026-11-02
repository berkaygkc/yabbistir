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
}
