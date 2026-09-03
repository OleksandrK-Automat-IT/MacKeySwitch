import Testing
import Foundation
@testable import LayoutSwitcher

/// End-to-end checks against the dictionaries the app actually ships with, rather than a
/// stub. The unit tests in LanguageDetectorTests prove the scoring is right; these prove
/// the scoring is fed data good enough to act on.
///
/// The frequency corpus must carry everyday words itself. The system dictionary is still
/// exercised as a fallback, but the app's basic correction path may not depend on an
/// optional macOS language dictionary being installed.
@Suite struct DictionaryCoverageTests {

    /// Keystrokes for a Ukrainian word typed with the US layout still active.
    private func typedOnUSLayout(_ ukrainian: String) -> [Keystroke] {
        keycodes(forTypingUkrainian: ukrainian)
    }

    private func correction(for keys: [Keystroke], layout: Language) -> Language? {
        LanguageDetector.detectIntended(
            keycodes: keys,
            currentLayout: layout,
            threshold: SettingsModel.Sensitivity.medium.scoreThreshold,
            settings: nil,
            dictionary: DictionaryManager.shared
        )
    }

    @Test func theSystemUkrainianDictionaryIsInstalled() {
        // Everything below depends on it. If this fails the app falls back to the bundled
        // list and everyday words stop being corrected.
        #expect(SystemSpellChecker.shared.supports(.ukrainian))
        #expect(SystemSpellChecker.shared.supports(.english))
    }

    @Test(arguments: ["привіт", "дякую", "добре", "треба", "зробити", "тобі", "скажи",
                      "завжди", "мені", "можна", "будь", "ласка", "сьогодні", "питання"])
    func everydayUkrainianTypedOnAUSLayoutIsCorrected(word: String) {
        try? #require(SystemSpellChecker.shared.supports(.ukrainian))
        let keys = typedOnUSLayout(word)
        #expect(keys.count == word.count, "'\(word)' does not map cleanly to US keys")
        #expect(correction(for: keys, layout: .english) == .ukrainian,
                "'\(word)' typed on a US layout was left uncorrected")
    }

    @Test(arguments: ["hello", "three", "wisdom", "thanks", "please", "always", "commit",
                      "branch", "review", "should", "people", "system"])
    func everydayEnglishIsNeverRewritten(word: String) {
        let keys = keycodes(forTyping: word)
        #expect(correction(for: keys, layout: .english) == nil,
                "'\(word)' was rewritten as Ukrainian")
    }

    @Test func theBundledUkrainianListCarriesEverydayWordsOffline() {
        #expect(DictionaryManager.shared.isUkrainianWord("привіт"))
        #expect(DictionaryManager.shared.isUkrainianWord("дякую"))
        #expect(DictionaryManager.shared.isUkrainianWord("клавіатура"))
        #expect(DictionaryManager.shared.isUkrainianWord("налаштування"))
        #expect(DictionaryManager.shared.isEnglishWord("hello"),
                "the test process did not load the bundled dictionaries")
        // The combined lookup continues to know them as well.
        #expect(DictionaryManager.shared.isWord("привіт", language: .ukrainian))
        #expect(DictionaryManager.shared.isWord("дякую", language: .ukrainian))
    }

    @Test func punctuationIsNotStrippedIntoAValidWord() {
        // A spell checker ignores punctuation and would call ",elm" English because "elm"
        // is. The buffer contains that punctuation for real: "будь" typed on a US layout
        // is ",elm", and accepting it as English vetoed the word's own correction.
        #expect(!DictionaryManager.shared.isWord(",elm", language: .english))
        #expect(!DictionaryManager.shared.isWord("elm.", language: .english))
        #expect(!DictionaryManager.shared.isWord("[hello", language: .english))

        let keys = typedOnUSLayout("будь")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .english) == ",elm")
        #expect(correction(for: keys, layout: .english) == .ukrainian)
    }

    @Test func garbageFromTypingEnglishOnAUkrainianLayoutIsNotAWord() {
        // The reverse direction's veto: these are what English words look like when the
        // Ukrainian layout is active, and none may be accepted as Ukrainian.
        for garbage in ["руддщ", "еркуу", "цшівщь", "ерфтлі", "здуфіу"] {
            #expect(!DictionaryManager.shared.isWord(garbage, language: .ukrainian),
                    "'\(garbage)' accepted as Ukrainian")
        }
    }
}
