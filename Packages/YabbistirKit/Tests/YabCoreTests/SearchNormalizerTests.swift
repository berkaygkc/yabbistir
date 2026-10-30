import Testing
@testable import YabCore

@Suite struct SearchNormalizerTests {
    @Test func dottedCapitalIFolds() {
        #expect(SearchNormalizer.normalize("İADE") == "iade")
    }

    @Test func englishCapitalIFolds() {
        #expect(SearchNormalizer.normalize("ISTANBUL") == "istanbul")
    }

    @Test func dotlessIFolds() {
        #expect(SearchNormalizer.normalize("ıspanak") == "ispanak")
    }

    @Test func turkishDiacriticsFold() {
        #expect(SearchNormalizer.normalize("Şeker Çay Ğ Ö Ü") == "seker cay g o u")
    }
}
