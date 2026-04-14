import Foundation

/// 3-stage detection algorithm (like PuntoSwitcher / xneur):
///   Stage 1: Check exception list (user overrides, self-learned words)
///   Stage 2: Check dictionaries (50k EN + 50k UA word files + NSSpellChecker)
///   Stage 3: Impossible bigram analysis (proto-language rules)
struct LanguageDetector {
    private static let dict = DictionaryManager.shared

    // MARK: - Early Detection (after 3rd char, real-time)

    /// Analyze partial word in real-time. Uses impossible bigrams for fast rejection.
    /// Returns intended language if wrong layout detected, nil if OK or uncertain.
    static func detectEarly(
        keycodes: [(UInt16, Bool)],
        currentLayout: Language,
        settings: SettingsModel?
    ) -> Language? {
        let enText = KeyMapping.reconstruct(keycodes: keycodes, language: .english)
        let uaText = KeyMapping.reconstruct(keycodes: keycodes, language: .ukrainian)

        // Stage 1: Exception list — never correct if the word user is ACTUALLY typing
        // (in the current layout) is an exception. Checking the OTHER reconstruction
        // would wrongly block a wrong-layout word whose correct-layout twin happens
        // to be in exceptions (e.g. typing "gthtdshrf" in EN while "перевірка" is excepted).
        if let settings = settings {
            let currentText = currentLayout == .english ? enText : uaText
            if settings.isException(currentText) {
                return nil
            }
        }

        switch currentLayout {
        case .english:
            // Currently English layout → typed text is Latin (enText)
            // Check: does enText contain impossible English bigrams?
            // AND does the Ukrainian reconstruction (uaText) look plausible?
            let enImpossible = ProtoLanguage.hasImpossibleEnglishBigram(enText)
            let uaPlausible = ProtoLanguage.couldBeUkrainian(uaText)

            if enImpossible && uaPlausible {
                // Also verify the UA prefix exists in dictionary
                if dict.isUkrainianPrefix(uaText) {
                    print("[LayoutSwitcher] Early: '\(enText)' has impossible EN bigram, '\(uaText)' is valid UA prefix")
                    return .ukrainian
                }
            }

            // Fallback: prefix-only check (no impossible bigram, but prefix doesn't exist)
            if !dict.isEnglishPrefix(enText) && dict.isUkrainianPrefix(uaText) {
                print("[LayoutSwitcher] Early: '\(enText)' not a valid EN prefix, '\(uaText)' is valid UA prefix")
                return .ukrainian
            }

        case .ukrainian:
            // Currently Ukrainian layout → typed text is Cyrillic (uaText)
            let uaImpossible = ProtoLanguage.hasImpossibleUkrainianBigram(uaText)
            let enPlausible = ProtoLanguage.couldBeEnglish(enText)

            if uaImpossible && enPlausible {
                if dict.isEnglishPrefix(enText) {
                    print("[LayoutSwitcher] Early: '\(uaText)' has impossible UA bigram, '\(enText)' is valid EN prefix")
                    return .english
                }
            }

            if !dict.isUkrainianPrefix(uaText) && dict.isEnglishPrefix(enText) {
                print("[LayoutSwitcher] Early: '\(uaText)' not a valid UA prefix, '\(enText)' is valid EN prefix")
                return .english
            }
        }

        return nil
    }

    // MARK: - Full Word Detection (on word boundary)

    /// Analyze complete word using all 3 stages.
    static func detectIntended(
        keycodes: [(UInt16, Bool)],
        currentLayout: Language,
        threshold: Double = 10.0,
        settings: SettingsModel?
    ) -> Language? {
        let enWord = KeyMapping.reconstruct(keycodes: keycodes, language: .english)
        let uaWord = KeyMapping.reconstruct(keycodes: keycodes, language: .ukrainian)

        // Stage 1: Exception list — see detectEarly for rationale (check only current layout).
        if let settings = settings {
            let currentWord = currentLayout == .english ? enWord : uaWord
            if settings.isException(currentWord) {
                print("[LayoutSwitcher] Word '\(currentWord)' is in exception list, skipping")
                return nil
            }
        }

        // Stage 2: Dictionary lookup
        let enIsWord = dict.isEnglishWord(enWord)
        let uaIsWord = dict.isUkrainianWord(uaWord)

        print("[LayoutSwitcher] Full word: EN '\(enWord)' dict=\(enIsWord), UA '\(uaWord)' dict=\(uaIsWord)")

        switch currentLayout {
        case .english:
            // Currently English. If UA reconstruction is a real word and EN is not → switch
            if uaIsWord && !enIsWord {
                return .ukrainian
            }
        case .ukrainian:
            // Currently Ukrainian. If EN reconstruction is a real word and UA is not → switch
            if enIsWord && !uaIsWord {
                return .english
            }
        }

        // Stage 3: Impossible bigram analysis (if dictionaries didn't help)
        switch currentLayout {
        case .english:
            let enImpossible = ProtoLanguage.hasImpossibleEnglishBigram(enWord)
            let uaPlausible = ProtoLanguage.couldBeUkrainian(uaWord)
            if enImpossible && uaPlausible && !enIsWord {
                print("[LayoutSwitcher] Stage 3: EN '\(enWord)' has impossible bigrams, UA '\(uaWord)' plausible")
                return .ukrainian
            }
        case .ukrainian:
            let uaImpossible = ProtoLanguage.hasImpossibleUkrainianBigram(uaWord)
            let enPlausible = ProtoLanguage.couldBeEnglish(enWord)
            if uaImpossible && enPlausible && !uaIsWord {
                print("[LayoutSwitcher] Stage 3: UA '\(uaWord)' has impossible bigrams, EN '\(enWord)' plausible")
                return .english
            }
        }

        return nil
    }
}
