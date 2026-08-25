import Foundation

/// Recognises a run of keystrokes as a password rather than a word, so the monitor leaves
/// it alone. Passwords are the worst thing to auto-correct: the user cannot see what was
/// mangled, and the field is often submitted immediately.
///
/// Digits and shifted digits carry most of the signal, and those keys are deliberately not
/// letter keys — they never enter the reconstruction buffer. The heuristic therefore has
/// to be fed *before* the monitor's letter-only filter, and it keeps its own length count
/// rather than reading the buffer's.
struct PasswordHeuristic {
    /// Printable keys since the word started, digits included.
    private(set) var printableCount = 0

    private var hasUpperCase = false
    private var hasLowerCase = false
    private var hasDigit = false
    private var hasSymbol = false

    /// Minimum length before a mixed-character run is treated as a password.
    static let minimumLength = 6

    /// Punctuation keys that are not letters on either layout: - = \ / (`_ + | ?` shifted).
    /// They always print a symbol, so they carry the same signal as a shifted digit.
    private static let symbolKeycodes: Set<UInt16> = [0x1B, 0x18, 0x2A, 0x2C]

    /// Feed one printable keystroke: a letter key, a number-row key, or a symbol key.
    mutating func record(keycode: UInt16, isShifted: Bool, capsLock: Bool = false) {
        if Self.symbolKeycodes.contains(keycode) {
            printableCount += 1
            hasSymbol = true
            return
        }

        guard KeyMapping.isLetterKey(keycode) || KeyMapping.numberRowKeycodes.contains(keycode)
        else { return }

        printableCount += 1

        if KeyMapping.numberRowKeycodes.contains(keycode) {
            if isShifted {
                hasSymbol = true
            } else {
                hasDigit = true
            }
            return
        }

        // Caps Lock uppercases letters too — and combined with Shift it types lowercase,
        // hence XOR. Without this, a caps-lock password never registered mixed case.
        if isShifted != capsLock {
            hasUpperCase = true
        } else {
            hasLowerCase = true
        }
    }

    /// Undo one keystroke's worth of length after a backspace. The character-class flags
    /// are deliberately sticky — reconstructing them would need the whole key history, and
    /// erring toward "might be a password" is the safe direction.
    mutating func removeLast() {
        printableCount = max(0, printableCount - 1)
    }

    mutating func reset() {
        self = PasswordHeuristic()
    }

    /// Mixed case plus digits or symbols, at a length no ordinary word reaches.
    var looksLikePassword: Bool {
        printableCount >= Self.minimumLength
            && hasUpperCase
            && hasLowerCase
            && (hasDigit || hasSymbol)
    }
}
