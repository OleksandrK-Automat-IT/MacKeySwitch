import Testing
import Foundation
@testable import LayoutSwitcher

// MARK: - Key tables

@Suite struct RussianKeyMappingTests {

    @Test func russianDiffersFromUkrainianOnExactlyTheMeasuredKeys() {
        // Measured with UCKeyTranslate against RussianWin and Ukrainian-PC: the two ЙЦУКЕН
        // layouts share every buffered key but these four.
        var differing: Set<UInt16> = []
        for keycode in KeyMapping.bufferedKeycodes {
            for shift in [false, true] {
                let stroke = Keystroke(keycode: keycode, shift: shift)
                if KeyMapping.character(for: stroke, language: .russian)
                    != KeyMapping.character(for: stroke, language: .ukrainian) {
                    differing.insert(keycode)
                }
            }
        }
        #expect(differing == [0x1E, 0x01, 0x27, 0x32])
    }

    @Test func everyBufferedKeyHasARussianCharacter() {
        // The backspace count rests on one character per keystroke, in every language.
        for keycode in KeyMapping.bufferedKeycodes {
            for shift in [false, true] {
                #expect(KeyMapping.character(for: Keystroke(keycode: keycode, shift: shift),
                                             language: .russian) != nil)
            }
        }
    }

    @Test func russianReadsTheMeasuredLetters() {
        #expect(KeyMapping.reconstruct(keycodes: keycodes(forTyping: "ghbdtn"), language: .russian) == "привет")
        let own = [Keystroke(keycode: 0x01), Keystroke(keycode: 0x1E),
                   Keystroke(keycode: 0x27), Keystroke(keycode: 0x32)]
        #expect(KeyMapping.reconstruct(keycodes: own, language: .russian) == "ыъэё")
        #expect(KeyMapping.reconstruct(keycodes: own, language: .ukrainian) == "іїєґ")
        let shifted = own.map { Keystroke(keycode: $0.keycode, shift: true) }
        // Latin Ë at the end: what the RussianWin layout actually prints for Shift+ё.
        #expect(KeyMapping.reconstruct(keycodes: shifted, language: .russian) == "ЫЪЭ\u{00CB}")
    }

    @Test func appleRussianPutsBracketsOnTheBacktickKey() {
        let legacy = KeyMapping.legacyRussianSourceID
        #expect(KeyMapping.character(for: Keystroke(keycode: 0x32), language: .russian, sourceID: legacy) == "]")
        #expect(KeyMapping.character(for: Keystroke(keycode: 0x32, shift: true), language: .russian, sourceID: legacy) == "[")
        #expect(KeyMapping.character(for: Keystroke(keycode: 0x32), language: .russian,
                                     sourceID: "com.apple.keylayout.RussianWin") == "ё")
    }

    @Test func capsLockUppercasesRussianLetters() {
        #expect(KeyMapping.character(for: Keystroke(keycode: 0x01, capsLock: true), language: .russian) == "Ы")
        #expect(KeyMapping.character(for: Keystroke(keycode: 0x01, shift: true, capsLock: true), language: .russian) == "ы")
    }
}

// MARK: - Pairing

@Suite struct LanguagePairingTests {

    @Test func cyrillicAlwaysPairsWithEnglish() {
        #expect(Language.ukrainian.correctionTarget(cyrillic: .russian) == .english)
        #expect(Language.russian.correctionTarget(cyrillic: .ukrainian) == .english)
    }

    @Test func englishPairsWithTheCyrillicItIsGiven() {
        #expect(Language.english.correctionTarget(cyrillic: .russian) == .russian)
        #expect(Language.english.correctionTarget(cyrillic: .ukrainian) == .ukrainian)
    }

    @Test func theHistoricalOppositeStillMeansTheUkrainianPair() {
        #expect(Language.english.opposite == .ukrainian)
        #expect(Language.russian.opposite == .english)
    }

    @Test func russianInputSourcesAreRecognisedExactly() {
        #expect(InputSourceManager.language(ofSourceID: "com.apple.keylayout.RussianWin") == .russian)
        #expect(InputSourceManager.language(ofSourceID: "com.apple.keylayout.Russian") == .russian)
        #expect(InputSourceManager.language(ofSourceID: "com.apple.keylayout.Russian-Phonetic") == nil,
                "a QWERTY-shaped layout has different geometry and must not be corrected")
    }
}

// MARK: - Engine

@Suite struct RussianEngineTests {
    private static let dictionary = StubDictionary(
        english: ["hello"], ukrainian: ["привіт"], russian: ["привет"]
    )

    private func harness(layout: Language, cyrillic: Language?) -> Harness {
        let h = Harness(dictionary: Self.dictionary)
        h.env.layout = layout
        h.env.cyrillic = cyrillic
        h.engine.seedCaches(frontmostBundleID: "com.example.editor")
        return h
    }

    @Test func englishGoesToRussianWhenRussianWasTheLastCyrillic() {
        let h = harness(layout: .english, cyrillic: .russian)
        h.type("ghbdtn")
        guard case .correct(let plan) = h.space() else { Issue.record("no correction"); return }
        #expect(plan.from == .english)
        #expect(plan.to == .russian)
        #expect(plan.correctText == "привет")
    }

    @Test func englishGoesToUkrainianWhenUkrainianWasTheLastCyrillic() {
        let h = harness(layout: .english, cyrillic: .ukrainian)
        h.type("ghbdsn")
        guard case .correct(let plan) = h.space() else { Issue.record("no correction"); return }
        #expect(plan.to == .ukrainian)
        #expect(plan.correctText == "привіт")
    }

    @Test func aRussianWordIsNotOfferedWhileUkrainianIsThePair() {
        // "привет" reads the same on both Cyrillic layouts, but it is only a Russian
        // word — and the pair is Ukrainian, so the detector never asks the Russian dictionary.
        let h = harness(layout: .english, cyrillic: .ukrainian)
        h.type("ghbdtn")
        #expect(h.space() == .nothing)
    }

    @Test func russianGoesBackToEnglish() {
        let h = harness(layout: .russian, cyrillic: .russian)
        h.type("hello")   // the keys h-e-l-l-o, which a Russian layout prints as руддщ
        guard case .correct(let plan) = h.space() else { Issue.record("no correction"); return }
        #expect(plan.from == .russian)
        #expect(plan.to == .english)
        #expect(plan.originalText == "руддщ")
        #expect(plan.correctText == "hello")
    }

    @Test func cyrillicNeverGoesToCyrillic() {
        // The keys of the Ukrainian word "привіт" on a Russian layout print "привыт". Even
        // with Ukrainian as the pair, a Cyrillic layout only ever goes back to English.
        let h = harness(layout: .russian, cyrillic: .ukrainian)
        h.type("ghbdsn")
        #expect(h.space() == .nothing)
    }

    @Test func nothingHappensWhenNoCyrillicLayoutIsEnabled() {
        let h = harness(layout: .english, cyrillic: nil)
        h.type("ghbdtn")
        #expect(h.space() == .nothing)
        h.type("ghbdsn")
        #expect(h.space() == .nothing)
    }

    @Test func theShortcutFollowsTheSamePairing() {
        let h = harness(layout: .english, cyrillic: .russian)
        h.type("ghbdtn")
        let plan = h.engine.onDemandPlan(isCorrecting: false)
        #expect(plan?.to == .russian)
        #expect(plan?.correctText == "привет")
    }
}

// MARK: - Selection and detection

@Suite struct RussianTransliterationTests {

    @Test func convertsBothWays() {
        #expect(LayoutTransliterator.convert("ghbdtn", to: .russian) == "привет")
        #expect(LayoutTransliterator.convert("привет", to: .english) == "ghbdtn")
        #expect(LayoutTransliterator.convert("ghbdsn", to: .ukrainian) == "привіт")
        #expect(LayoutTransliterator.convert("привыт", to: .english) == "ghbdsn")
    }

    @Test func tellsTheCyrillicLayoutsApartByTheirOwnLetters() {
        #expect(LayoutTransliterator.detectLanguage(of: "привыт") == .russian)
        #expect(LayoutTransliterator.detectLanguage(of: "привіт", preferredCyrillic: .russian) == .ukrainian)
    }

    @Test func sharedLettersFollowThePreferredLayout() {
        #expect(LayoutTransliterator.detectLanguage(of: "привет") == .ukrainian)
        #expect(LayoutTransliterator.detectLanguage(of: "привет", preferredCyrillic: .russian) == .russian)
    }

    @Test func theDetectorNamesTheTargetItWasGiven() {
        let intended = LanguageDetector.detectIntended(
            keycodes: keycodes(forTyping: "ghbdtn"), currentLayout: .english, target: .russian,
            threshold: SettingsModel.Sensitivity.medium.scoreThreshold, settings: nil,
            dictionary: StubDictionary(russian: ["привет"])
        )
        #expect(intended == .russian)
    }

    @Test func russianScriptAndPlausibility() {
        #expect(ProtoLanguage.usesScript("привет", of: .russian))
        #expect(!ProtoLanguage.usesScript("hello", of: .russian))
        #expect(ProtoLanguage.couldBe("привет", language: .russian))
        #expect(!ProtoLanguage.hasImpossibleBigram("привет", language: .russian))
    }

    @Test func theSystemDictionaryCarriesRussian() throws {
        try #require(SystemSpellChecker.shared.supports(.russian))
        #expect(DictionaryManager.shared.isWord("привет", language: .russian))
        #expect(!DictionaryManager.shared.isWord("привіт", language: .russian))
        #expect(DictionaryManager.shared.isPrefix("зхч", language: .russian),
                "no corpus, so no prefix can be called invalid")
    }
}
