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

    /// The titles are measured in the font the system's sidebar size gives them (11, 13 or 15 pt): larger rows make a
    /// long title's sidebar wider, never narrower.
    @Test func theSidebarFollowsTheSystemRowSize() {
        #expect(SettingsSection.sidebarWidth(.english, rowSize: .medium) == SettingsSection.sidebarWidth(.english))
        for language in AppLanguage.allCases {
            let small = SettingsSection.sidebarWidth(language, rowSize: .small)
            let medium = SettingsSection.sidebarWidth(language, rowSize: .medium)
            let large = SettingsSection.sidebarWidth(language, rowSize: .large)
            #expect(small <= medium && medium <= large, "\(language.rawValue): \(small), \(medium), \(large)")
            #expect(large <= 260)
        }
        // "キーボードショートカット" is about 125, 148 and 171 pt wide at the three sizes.
        #expect(SettingsSection.sidebarWidth(.japanese, rowSize: .small) < SettingsSection.sidebarWidth(.japanese, rowSize: .medium))
        #expect(SettingsSection.sidebarWidth(.japanese, rowSize: .medium) < SettingsSection.sidebarWidth(.japanese, rowSize: .large))
    }
}
