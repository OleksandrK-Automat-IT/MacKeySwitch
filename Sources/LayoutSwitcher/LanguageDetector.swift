import Foundation

/// Dictionary lookups the detector needs. A protocol so the scoring logic can be
/// exercised in tests against a fixed word list instead of the 50k bundled corpus.
protocol WordSource {
    func isWord(_ word: String, language: Language) -> Bool
    func isPrefix(_ prefix: String, language: Language) -> Bool
}

/// Decides whether a buffered word was typed in the wrong keyboard layout.
///
/// Every signal contributes to a single confidence score, which is compared against the
/// threshold picked by the user's Sensitivity setting. Scoring replaces the previous
/// cascade of independent `if` rules, where the Sensitivity setting had nothing to
/// attach to and was silently ignored.
struct LanguageDetector {

    /// Score contributions.
    ///
    /// Tuned against the thresholds in `SettingsModel.Sensitivity`: a dictionary hit on
    /// the target language (14) plus any one supporting signal clears Medium (10), while
    /// the strongest possible evidence *without* a dictionary hit sums to 9 — deliberately
    /// just under Medium, so the default setting never rewrites a word neither dictionary
    /// recognises. Low (20) additionally requires three of the four supporting signals.
    enum Weight {
        static let targetIsWord = 14
        static let currentIsWord = -25
        static let currentHasImpossibleBigram = 3
        static let targetPlausible = 2
        static let targetPrefixValid = 2
        static let currentPrefixInvalid = 2
    }

    /// The signals gathered for one candidate correction, kept separate from the score so
    /// tests can assert on individual signals and on the total independently.
    struct Evidence: Equatable {
        /// The other-layout reading is a real word.
        var targetIsWord = false
        /// What the user actually typed is a real word — a veto, not just a penalty.
        var currentIsWord = false
        /// What the user typed contains a letter pair the current language never uses.
        var currentHasImpossibleBigram = false
        /// The other-layout reading is in the right script and has no impossible pairs.
        var targetPlausible = false
        /// The other-layout reading starts like some word in the target dictionary.
        var targetPrefixValid = false
        /// What the user typed starts like no word in the current dictionary.
        var currentPrefixInvalid = false

        var score: Int {
            var total = 0
            if targetIsWord { total += Weight.targetIsWord }
            if currentIsWord { total += Weight.currentIsWord }
            if currentHasImpossibleBigram { total += Weight.currentHasImpossibleBigram }
            if targetPlausible { total += Weight.targetPlausible }
            if targetPrefixValid { total += Weight.targetPrefixValid }
            if currentPrefixInvalid { total += Weight.currentPrefixInvalid }
            return total
        }
    }

    // MARK: - Scoring

    /// Weigh a candidate correction. `currentText` is what the keystrokes produce in the
    /// active layout; `targetText` is the same keystrokes read in the other layout.
    static func gatherEvidence(
        currentText: String,
        targetText: String,
        currentLanguage: Language,
        dictionary: WordSource
    ) -> Evidence {
        let target = currentLanguage.opposite
        var evidence = Evidence()

        evidence.currentIsWord = dictionary.isWord(currentText, language: currentLanguage)
        evidence.targetIsWord = dictionary.isWord(targetText, language: target)
        evidence.currentHasImpossibleBigram =
            ProtoLanguage.hasImpossibleBigram(currentText, language: currentLanguage)
        evidence.targetPlausible = ProtoLanguage.couldBe(targetText, language: target)
        evidence.targetPrefixValid = dictionary.isPrefix(targetText, language: target)
        evidence.currentPrefixInvalid = !dictionary.isPrefix(currentText, language: currentLanguage)

        return evidence
    }

    // MARK: - Full Word Detection (on word boundary)

    /// Analyse a completed word. Returns the language it should be retyped in, or nil to
    /// leave it alone.
    static func detectIntended(
        keycodes: [Keystroke],
        currentLayout: Language,
        threshold: Int,
        settings: SettingsModel?,
        dictionary: WordSource = DictionaryManager.shared
    ) -> Language? {
        let target = currentLayout.opposite
        let currentText = KeyMapping.reconstruct(keycodes: keycodes, language: currentLayout)
        let targetText = KeyMapping.reconstruct(keycodes: keycodes, language: target)

        // Exceptions are keyed on what the user actually typed. Checking the other
        // reading instead would block a genuinely wrong-layout word whose correct-layout
        // twin happens to be excepted.
        if let settings = settings, settings.isException(currentText) {
            debugLog("[LayoutSwitcher] '\(currentText)' is an exception, skipping")
            return nil
        }

        let evidence = gatherEvidence(
            currentText: currentText,
            targetText: targetText,
            currentLanguage: currentLayout,
            dictionary: dictionary
        )
        let score = evidence.score

        debugLog("[LayoutSwitcher] '\(currentText)' -> '\(targetText)': score \(score) "
                 + "vs threshold \(threshold) \(evidence)")

        return score >= threshold ? target : nil
    }
}
