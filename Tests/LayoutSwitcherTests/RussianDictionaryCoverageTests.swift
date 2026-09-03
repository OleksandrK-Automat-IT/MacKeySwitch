import Testing
@testable import LayoutSwitcher

@Suite struct RussianDictionaryCoverageTests {
    @Test func customRussianWordsAreLookedUpAndPrefixed() {
        // An isolated manager: nothing bundled for Russian, so only what is added counts.
        let manager = DictionaryManager()
        #expect(!manager.isRussianWord("тестслово"))
        manager.addCustomRussianWords(["Тестслово"])
        #expect(manager.isRussianWord("тестслово"))
        #expect(manager.isRussianPrefix("тес"))
        #expect(!manager.isRussianPrefix("зхч"), "once a Russian corpus exists, prefixes are judged by it")
    }

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
