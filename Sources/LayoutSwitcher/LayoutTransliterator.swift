import Foundation

/// Re-reads text as though it had been typed with the other keyboard layout.
///
/// The word-boundary corrector works from buffered keycodes, which it still has. Selection
/// correction has only the characters on screen, so it maps character to character using
/// the same physical-key correspondence: whatever key produces "g" on a US layout produces
/// "п" on a Ukrainian one.
enum LayoutTransliterator {

    /// Built from `KeyMapping`, so the two paths cannot drift apart: a key added there is
    /// transliterable here for free. One table per Cyrillic layout going out; a single
    /// table coming back, because the two Cyrillic layouts share every key they have in
    /// common and each contributes its own letters for the rest.
    private static let tables: (toUkrainian: [Character: Character],
                                toRussian: [Character: Character],
                                toEnglish: [Character: Character]) = {
        var toUkrainian: [Character: Character] = [:]
        var toRussian: [Character: Character] = [:]
        var toEnglish: [Character: Character] = [:]
        for keycode in KeyMapping.unshifted.keys {
            for shift in [false, true] {
                let stroke = Keystroke(keycode: keycode, shift: shift)
                guard let en = KeyMapping.character(for: stroke, language: .english),
                      let ua = KeyMapping.character(for: stroke, language: .ukrainian),
                      let ru = KeyMapping.character(for: stroke, language: .russian) else { continue }
                // Digits map to themselves on every layout; keeping them out leaves them to
                // pass through untouched, which is the same result with less to go wrong.
                if en != ua { toUkrainian[en] = ua; toEnglish[ua] = en }
                if en != ru { toRussian[en] = ru; toEnglish[ru] = en }
            }
        }
        return (toUkrainian, toRussian, toEnglish)
    }()

    /// Letters only one of the two Cyrillic layouts can type. What tells them apart.
    private static let ukrainianOnly: Set<Character> = ["і", "ї", "є", "ґ"]
    private static let russianOnly: Set<Character> = ["ы", "э", "ъ", "ё"]

    /// Convert `text` into `language`. Characters with no counterpart — spaces, digits,
    /// emoji — are left alone, so a whole sentence converts without losing its shape.
    static func convert(_ text: String, to language: Language) -> String {
        let table: [Character: Character]
        switch language {
        case .ukrainian: table = tables.toUkrainian
        case .russian: table = tables.toRussian
        case .english: table = tables.toEnglish
        }
        return String(text.map { table[$0] ?? $0 })
    }

    /// Which layout the text reads as, by counting letters of each script.
    ///
    /// Counting rather than sampling the first letter: real selections start with quotes,
    /// digits or brackets often enough that the first character is a poor witness. Returns
    /// nil when there is nothing to judge by, or when the two scripts are evenly matched —
    /// converting a genuinely mixed selection would corrupt half of it either way.
    ///
    /// Cyrillic text is Ukrainian or Russian by the letters only one of them has; text
    /// made entirely of shared letters is attributed to `preferredCyrillic`, the layout the
    /// user last worked in. Converting to English reads the same either way.
    static func detectLanguage(of text: String, preferredCyrillic: Language = .ukrainian) -> Language? {
        var latin = 0
        var cyrillic = 0
        var ukrainianMarks = 0
        var russianMarks = 0
        for character in text {
            if tables.toUkrainian[character] != nil || tables.toRussian[character] != nil {
                latin += 1
            } else if tables.toEnglish[character] != nil {
                cyrillic += 1
                let lower = Character(character.lowercased())
                if ukrainianOnly.contains(lower) { ukrainianMarks += 1 }
                if russianOnly.contains(lower) { russianMarks += 1 }
            }
        }
        if latin == cyrillic { return nil }
        if latin > cyrillic { return .english }
        if ukrainianMarks != russianMarks { return ukrainianMarks > russianMarks ? .ukrainian : .russian }
        return preferredCyrillic.isCyrillic ? preferredCyrillic : .ukrainian
    }
}
