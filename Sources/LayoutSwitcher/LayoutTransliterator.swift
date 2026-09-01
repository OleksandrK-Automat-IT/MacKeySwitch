import Foundation

/// Re-reads text as though it had been typed with the other keyboard layout.
///
/// The word-boundary corrector works from buffered keycodes, which it still has. Selection
/// correction has only the characters on screen, so it maps character to character using
/// the same physical-key correspondence: whatever key produces "g" on a US layout produces
/// "п" on a Ukrainian one.
enum LayoutTransliterator {

    /// Built from `KeyMapping`, so the two paths cannot drift apart: a key added there is
    /// transliterable here for free.
    private static let tables: (englishToUkrainian: [Character: Character],
                                ukrainianToEnglish: [Character: Character]) = {
        var toUkrainian: [Character: Character] = [:]
        var toEnglish: [Character: Character] = [:]
        for map in [KeyMapping.unshifted, KeyMapping.shifted] {
            for pair in map.values {
                // Digits map to themselves on both layouts; keeping them out leaves them to
                // pass through untouched, which is the same result with less to go wrong.
                guard pair.en != pair.ua else { continue }
                toUkrainian[pair.en] = pair.ua
                toEnglish[pair.ua] = pair.en
            }
        }
        return (toUkrainian, toEnglish)
    }()

    /// Convert `text` into `language`. Characters with no counterpart — spaces, digits,
    /// emoji — are left alone, so a whole sentence converts without losing its shape.
    static func convert(_ text: String, to language: Language) -> String {
        let table = language == .ukrainian ? tables.englishToUkrainian : tables.ukrainianToEnglish
        return String(text.map { table[$0] ?? $0 })
    }

    /// Which layout the text reads as, by counting letters of each script.
    ///
    /// Counting rather than sampling the first letter: real selections start with quotes,
    /// digits or brackets often enough that the first character is a poor witness. Returns
    /// nil when there is nothing to judge by, or when the two scripts are evenly matched —
    /// converting a genuinely mixed selection would corrupt half of it either way.
    static func detectLanguage(of text: String) -> Language? {
        var latin = 0
        var cyrillic = 0
        for character in text {
            if tables.englishToUkrainian[character] != nil {
                latin += 1
            } else if tables.ukrainianToEnglish[character] != nil {
                cyrillic += 1
            }
        }
        if latin == cyrillic { return nil }
        return latin > cyrillic ? .english : .ukrainian
    }
}
