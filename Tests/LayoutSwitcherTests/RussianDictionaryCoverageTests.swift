import Testing
@testable import LayoutSwitcher

@Suite struct RussianDictionaryCoverageTests {
    @Test func capitalisedRussianWordTypedInEnglishIsDetected() throws {
        try #require(SystemSpellChecker.shared.supports(.russian))
        for text in ["Ghbdtn", "ghbdtn"] {
            let keys = keycodes(forTyping: text)
            #expect(KeyMapping.reconstruct(keycodes: keys, language: .russian).lowercased() == "привет")
            let intended = LanguageDetector.detectIntended(
                keycodes: keys, currentLayout: .english, target: .russian,
                threshold: SettingsModel.Sensitivity.high.scoreThreshold, settings: nil,
                dictionary: DictionaryManager.shared)
            #expect(intended == .russian, "\(text)")
        }
    }
}
