import Foundation

/// One buffered keypress: the physical key plus the modifier state that decides which
/// character it produced.
///
/// Caps Lock is carried separately from Shift because the two do not mean the same thing
/// for every key on this map. Several US-layout punctuation keys are Ukrainian letters
/// (';' is 'ж', ',' is 'б'), so the same keystroke is case-sensitive in one language and
/// not in the other — a single "isShifted" flag cannot express that, and reconstructing
/// with one dropped the capitals of anything typed with Caps Lock on.
struct Keystroke: Equatable {
    let keycode: UInt16
    /// Shift was held. Selects the shifted character map.
    let shift: Bool
    /// Caps Lock was on. Inverts the case of letters only, per the macOS convention that
    /// Shift+Caps Lock types lowercase.
    let capsLock: Bool

    init(keycode: UInt16, shift: Bool = false, capsLock: Bool = false) {
        self.keycode = keycode
        self.shift = shift
        self.capsLock = capsLock
    }
}

// Maps macOS virtual keycodes to characters for English (US) and Ukrainian layouts.
// Only letter/number keys are mapped — modifiers, arrows, function keys are excluded.
struct KeyMapping {
    struct CharPair {
        let en: Character
        let ua: Character
    }

    // macOS virtual keycode → (English char, Ukrainian char) for unshifted keys
    // Based on standard US QWERTY and Ukrainian layouts
    static let unshifted: [UInt16: CharPair] = [
        // Row 1: number row
        0x12: CharPair(en: "1", ua: "1"),
        0x13: CharPair(en: "2", ua: "2"),
        0x14: CharPair(en: "3", ua: "3"),
        0x15: CharPair(en: "4", ua: "4"),
        0x17: CharPair(en: "5", ua: "5"),
        0x16: CharPair(en: "6", ua: "6"),
        0x1A: CharPair(en: "7", ua: "7"),
        0x1C: CharPair(en: "8", ua: "8"),
        0x19: CharPair(en: "9", ua: "9"),
        0x1D: CharPair(en: "0", ua: "0"),

        // Row 2: QWERTY / ЙЦУКЕН
        0x0C: CharPair(en: "q", ua: "й"),
        0x0D: CharPair(en: "w", ua: "ц"),
        0x0E: CharPair(en: "e", ua: "у"),
        0x0F: CharPair(en: "r", ua: "к"),
        0x11: CharPair(en: "t", ua: "е"),
        0x10: CharPair(en: "y", ua: "н"),
        0x20: CharPair(en: "u", ua: "г"),
        0x22: CharPair(en: "i", ua: "ш"),
        0x1F: CharPair(en: "o", ua: "щ"),
        0x23: CharPair(en: "p", ua: "з"),
        0x21: CharPair(en: "[", ua: "х"),
        0x1E: CharPair(en: "]", ua: "ї"),

        // Row 3: ASDF / ФІВА
        0x00: CharPair(en: "a", ua: "ф"),
        0x01: CharPair(en: "s", ua: "і"),
        0x02: CharPair(en: "d", ua: "в"),
        0x03: CharPair(en: "f", ua: "а"),
        0x05: CharPair(en: "g", ua: "п"),
        0x04: CharPair(en: "h", ua: "р"),
        0x26: CharPair(en: "j", ua: "о"),
        0x28: CharPair(en: "k", ua: "л"),
        0x25: CharPair(en: "l", ua: "д"),
        0x29: CharPair(en: ";", ua: "ж"),
        0x27: CharPair(en: "'", ua: "є"),

        // Row 4: ZXCV / ЯЧСМ
        0x06: CharPair(en: "z", ua: "я"),
        0x07: CharPair(en: "x", ua: "ч"),
        0x08: CharPair(en: "c", ua: "с"),
        0x09: CharPair(en: "v", ua: "м"),
        0x0B: CharPair(en: "b", ua: "и"),
        0x2D: CharPair(en: "n", ua: "т"),
        0x2E: CharPair(en: "m", ua: "ь"),
        0x2B: CharPair(en: ",", ua: "б"),
        0x2F: CharPair(en: ".", ua: "ю"),

        // Backtick / ґ
        0x32: CharPair(en: "`", ua: "ґ"),
    ]

    // Shifted variants
    static let shifted: [UInt16: CharPair] = [
        0x0C: CharPair(en: "Q", ua: "Й"),
        0x0D: CharPair(en: "W", ua: "Ц"),
        0x0E: CharPair(en: "E", ua: "У"),
        0x0F: CharPair(en: "R", ua: "К"),
        0x11: CharPair(en: "T", ua: "Е"),
        0x10: CharPair(en: "Y", ua: "Н"),
        0x20: CharPair(en: "U", ua: "Г"),
        0x22: CharPair(en: "I", ua: "Ш"),
        0x1F: CharPair(en: "O", ua: "Щ"),
        0x23: CharPair(en: "P", ua: "З"),
        0x21: CharPair(en: "{", ua: "Х"),
        0x1E: CharPair(en: "}", ua: "Ї"),

        0x00: CharPair(en: "A", ua: "Ф"),
        0x01: CharPair(en: "S", ua: "І"),
        0x02: CharPair(en: "D", ua: "В"),
        0x03: CharPair(en: "F", ua: "А"),
        0x05: CharPair(en: "G", ua: "П"),
        0x04: CharPair(en: "H", ua: "Р"),
        0x26: CharPair(en: "J", ua: "О"),
        0x28: CharPair(en: "K", ua: "Л"),
        0x25: CharPair(en: "L", ua: "Д"),
        0x29: CharPair(en: ":", ua: "Ж"),
        0x27: CharPair(en: "\"", ua: "Є"),

        0x06: CharPair(en: "Z", ua: "Я"),
        0x07: CharPair(en: "X", ua: "Ч"),
        0x08: CharPair(en: "C", ua: "С"),
        0x09: CharPair(en: "V", ua: "М"),
        0x0B: CharPair(en: "B", ua: "И"),
        0x2D: CharPair(en: "N", ua: "Т"),
        0x2E: CharPair(en: "M", ua: "Ь"),
        0x2B: CharPair(en: "<", ua: "Б"),
        0x2F: CharPair(en: ">", ua: "Ю"),

        0x32: CharPair(en: "~", ua: "Ґ"),
    ]

    /// The keys this map covers, and the only ones that ever enter the reconstruction
    /// buffer. Exposed so the layout can be asked which of them are dead keys — see
    /// `InputSourceManager.deadKeyProfile()`.
    static let bufferedKeycodes: Set<UInt16> = [
        0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x10, 0x20, 0x22, 0x1F, 0x23, // qwertyuiop
        0x00, 0x01, 0x02, 0x03, 0x05, 0x04, 0x26, 0x28, 0x25,       // asdfghjkl
        0x06, 0x07, 0x08, 0x09, 0x0B, 0x2D, 0x2E,                     // zxcvbnm
        0x21, 0x1E, 0x29, 0x27, 0x2B, 0x2F, 0x32,                     // brackets, punct mapped to UA letters
    ]

    /// Returns true if the keycode is a letter key (not punctuation/number)
    static func isLetterKey(_ keycode: UInt16) -> Bool {
        bufferedKeycodes.contains(keycode)
    }

    /// Number-row keycodes. These are deliberately absent from `isLetterKey` — they are
    /// never buffered for reconstruction — but they are the strongest password signal,
    /// so password detection has to look at them separately.
    static let numberRowKeycodes: Set<UInt16> = [
        0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D,
    ]

    /// Word boundary keycodes: space, return, tab
    static let wordBoundaryKeycodes: Set<UInt16> = [
        0x31, // space
        0x24, // return
        0x30, // tab
    ]

    /// Boundaries that may trigger a correction — space only.
    ///
    /// Return and Tab end a word but must not start one: the correction runs
    /// asynchronously, ~150ms after the key already went through. By then Return has
    /// sent the message in a chat client and Tab has moved focus to the next field, so
    /// the replacement text would be typed into an empty compose box or the wrong field.
    static let correctionTriggerKeycodes: Set<UInt16> = [
        0x31, // space
    ]

    /// Backspace keycode
    static let backspaceKeycode: UInt16 = 0x33

    /// Space keycode
    static let spaceKeycode: UInt16 = 0x31

    /// The character one keystroke produces in the given language, or nil for a key this
    /// map does not cover.
    ///
    /// Guaranteed to be exactly one character. The correction erases the old word with a
    /// counted run of backspaces, so a keystroke that expanded to two characters — or to
    /// none — would leave the caret in the wrong place and shred the surrounding text.
    static func character(for stroke: Keystroke, language: Language) -> Character? {
        let map = stroke.shift ? shifted : unshifted
        guard let pair = map[stroke.keycode] else { return nil }
        let base = language == .english ? pair.en : pair.ua

        // Caps Lock only affects letters: ';' stays ';' but 'ж' becomes 'Ж'. Combined with
        // Shift it types lowercase, which is why this inverts rather than uppercases.
        guard stroke.capsLock, base.isLetter else { return base }
        let flipped = stroke.shift ? base.lowercased() : base.uppercased()
        // A case change that is not one-to-one (no such pair in these alphabets, but the
        // Unicode rules allow it) would break the backspace count. Keep the original.
        guard flipped.count == 1, let char = flipped.first else { return base }
        return char
    }

    /// Reconstruct text from buffered keystrokes for a given language
    static func reconstruct(keycodes: [Keystroke], language: Language) -> String {
        var result = ""
        for stroke in keycodes {
            guard let char = character(for: stroke, language: language) else { continue }
            result.append(char)
        }
        return result
    }
}

enum Language: String, CaseIterable {
    case english
    case ukrainian

    /// The only other language this app knows about — the correction target.
    var opposite: Language {
        self == .english ? .ukrainian : .english
    }

    /// Name for display, in whatever language the interface is currently set to.
    /// `rawValue` is an identifier, not a label — it used to be capitalised and shown
    /// directly, which left "English"/"Ukrainian" in the UI whatever the chosen language.
    var localizedName: String {
        switch self {
        case .english: return L("language.english")
        case .ukrainian: return L("language.ukrainian")
        }
    }
}
