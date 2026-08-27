import Testing
@testable import LayoutSwitcher

/// The detector decides whether to silently rewrite what the user just typed, so the two
/// failure modes are not symmetric: missing a wrong-layout word is a nuisance, rewriting a
/// correctly typed one destroys input. These tests pin both directions, and pin that the
/// Sensitivity setting actually moves the line — it used to be read from settings, passed
/// as a parameter, and then never used.
@Suite struct LanguageDetectorTests {

    /// "ghbdsn" on a US layout is what typing "привіт" looks like with the wrong layout active.
    static let wrongLayoutKeys = keycodes(forTyping: "ghbdsn")

    static let dictionary = StubDictionary(
        english: ["hello", "three", "wisdom", "the", "there", "ghost"],
        ukrainian: ["привіт", "привід", "руда"]
    )

    private func detect(
        _ text: String,
        layout: Language,
        sensitivity: SettingsModel.Sensitivity,
        dictionary: StubDictionary = LanguageDetectorTests.dictionary
    ) -> Language? {
        LanguageDetector.detectIntended(
            keycodes: keycodes(forTyping: text),
            currentLayout: layout,
            threshold: sensitivity.scoreThreshold,
            settings: nil,
            dictionary: dictionary
        )
    }

    /// As `detect`, but the text is given in Ukrainian and typed on the Ukrainian layout.
    private func detect(
        keycodesText: String,
        layout: Language,
        sensitivity: SettingsModel.Sensitivity,
        dictionary: StubDictionary = LanguageDetectorTests.dictionary
    ) -> Language? {
        LanguageDetector.detectIntended(
            keycodes: keycodes(forTypingUkrainian: keycodesText),
            currentLayout: layout,
            threshold: sensitivity.scoreThreshold,
            settings: nil,
            dictionary: dictionary
        )
    }

    // MARK: - Correcting genuinely wrong layouts

    @Test func wrongLayoutWordIsCorrectedToUkrainian() {
        #expect(detect("ghbdsn", layout: .english, sensitivity: .medium) == .ukrainian)
    }

    @Test func wrongLayoutWordIsCorrectedToEnglish() {
        // Typing "hello" while the Ukrainian layout is active.
        #expect(detect("hello", layout: .ukrainian, sensitivity: .medium) == .english)
    }

    @Test func aWrongLayoutWordIsCorrectedEvenAtTheLeastAggressiveSetting() {
        #expect(detect("ghbdsn", layout: .english, sensitivity: .low) == .ukrainian)
    }

    // MARK: - Leaving correct typing alone

    @Test(arguments: [SettingsModel.Sensitivity.low, .medium, .high, .veryHigh])
    func aRealEnglishWordIsNeverRewritten(sensitivity: SettingsModel.Sensitivity) {
        // Regression: "three" used to trip the "hr" impossible-bigram rule, and early
        // detection could act on that without ever re-checking the finished word.
        #expect(detect("three", layout: .english, sensitivity: sensitivity) == nil)
        #expect(detect("wisdom", layout: .english, sensitivity: sensitivity) == nil)
        #expect(detect("hello", layout: .english, sensitivity: sensitivity) == nil)
    }

    @Test func aRealUkrainianWordIsNotRewritten() {
        // "ghbdsn" reads as "привіт" on a Ukrainian layout, which is a real word there.
        #expect(detect("ghbdsn", layout: .ukrainian, sensitivity: .medium) == nil)
    }

    // MARK: - Sensitivity actually changes behaviour

    @Test(arguments: [SettingsModel.Sensitivity.low, .medium, .high, .veryHigh])
    func aWordNeitherDictionaryKnowsIsNeverRewritten(sensitivity: SettingsModel.Sensitivity) {
        // "vkzx" is in no dictionary and is full of pairs English never uses, so every
        // supporting signal fires — but the other reading is not a word either, so there
        // is no evidence the *other* layout was intended. It used to be rewritten at the
        // two most aggressive settings; nothing distinguishes it from a name or an
        // unlisted inflection, both of which are correct input.
        #expect(detect("vkzx", layout: .english, sensitivity: sensitivity) == nil)
    }

    /// The regression that prompted the gate: real words the 50k lists happen not to
    /// contain scored 2 on `currentPrefixInvalid` alone — exactly the Very High threshold —
    /// and were replaced with Latin gibberish as the user typed.
    @Test(arguments: [SettingsModel.Sensitivity.low, .medium, .high, .veryHigh])
    func anUnlistedUkrainianWordIsNotRewritten(sensitivity: SettingsModel.Sensitivity) {
        // "київ" is absent from the stub dictionary, as it is from the bundled corpus.
        #expect(detect(keycodesText: "київ", layout: .ukrainian, sensitivity: sensitivity) == nil)
    }

    @Test func thresholdsAreOrderedFromLeastToMostAggressive() {
        let thresholds = [
            SettingsModel.Sensitivity.low,
            .medium,
            .high,
            .veryHigh,
        ].map(\.scoreThreshold)
        #expect(thresholds == thresholds.sorted(by: >))
    }

    @Test func loweringTheThresholdNeverUndoesACorrection() {
        // Monotonicity: whatever triggers at a strict setting must still trigger at a
        // looser one. Guards against future weights that make sensitivity non-monotonic.
        let order: [SettingsModel.Sensitivity] = [.low, .medium, .high, .veryHigh]
        for text in ["ghbdsn", "vkzx", "three", "hello"] {
            var corrected = false
            for sensitivity in order {
                let result = detect(text, layout: .english, sensitivity: sensitivity)
                if corrected {
                    #expect(result != nil, "'\(text)' stopped being corrected at \(sensitivity)")
                }
                corrected = corrected || result != nil
            }
        }
    }

    // MARK: - Scoring

    @Test func aDictionaryHitOnWhatTheUserTypedVetoesTheCorrection() {
        var evidence = LanguageDetector.Evidence()
        evidence.currentIsWord = true
        evidence.targetIsWord = true
        evidence.currentHasImpossibleBigram = true
        evidence.targetPlausible = true
        evidence.targetPrefixValid = true
        evidence.currentPrefixInvalid = true
        #expect(evidence.score < SettingsModel.Sensitivity.veryHigh.scoreThreshold)
    }

    @Test func evidenceWithoutADictionaryHitStaysBelowTheDefaultThreshold() {
        // The design constraint behind the weights: at the default (medium) setting the
        // app never rewrites a word neither dictionary recognises.
        var evidence = LanguageDetector.Evidence()
        evidence.currentHasImpossibleBigram = true
        evidence.targetPlausible = true
        evidence.targetPrefixValid = true
        evidence.currentPrefixInvalid = true
        #expect(evidence.score < SettingsModel.Sensitivity.medium.scoreThreshold)
    }

    @Test func aDictionaryHitPlusOneSignalClearsTheDefaultThreshold() {
        var evidence = LanguageDetector.Evidence()
        evidence.targetIsWord = true
        evidence.targetPlausible = true
        #expect(evidence.score >= SettingsModel.Sensitivity.medium.scoreThreshold)
    }

    @Test func emptyEvidenceScoresZero() {
        #expect(LanguageDetector.Evidence().score == 0)
    }

    @Test func evidenceReflectsTheDictionary() {
        let evidence = LanguageDetector.gatherEvidence(
            currentText: "ghbdsn",
            targetText: "привіт",
            currentLanguage: .english,
            dictionary: Self.dictionary
        )
        #expect(evidence.targetIsWord)
        #expect(!evidence.currentIsWord)
        #expect(evidence.targetPlausible)
    }
}
