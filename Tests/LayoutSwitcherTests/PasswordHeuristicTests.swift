import Testing
@testable import LayoutSwitcher

/// This heuristic was previously unreachable: it was fed only after the monitor's
/// letter-only filter, so its digit and symbol flags could never be set and it never
/// suppressed a single correction. These tests assert it actually fires.
@Suite struct PasswordHeuristicTests {

    /// Feeds a string the way the monitor does — every printable key, digits included.
    private func heuristic(after text: String) -> PasswordHeuristic {
        var heuristic = PasswordHeuristic()
        for stroke in keycodes(forTyping: text) {
            heuristic.record(keycode: stroke.keycode, isShifted: stroke.shift)
        }
        return heuristic
    }

    @Test func recognisesAMixedCasePasswordWithDigits() {
        #expect(heuristic(after: "Passw1").looksLikePassword)
        #expect(heuristic(after: "Tr0ub4dor").looksLikePassword)
    }

    @Test func recognisesAMixedCasePasswordWithSymbols() {
        // A shifted number-row key is a symbol (!@#$%…). Fed by keycode because the
        // shifted map only covers letters — symbols are never reconstructed as text.
        var heuristic = heuristic(after: "Passw")
        heuristic.record(keycode: 0x12, isShifted: true) // shift+1
        #expect(heuristic.looksLikePassword)
    }

    @Test func ordinaryWordsAreNotPasswords() {
        #expect(!heuristic(after: "hello").looksLikePassword)
        #expect(!heuristic(after: "Hello").looksLikePassword)
        #expect(!heuristic(after: "Password").looksLikePassword)
    }

    @Test func digitsAloneAreNotEnough() {
        #expect(!heuristic(after: "abc123").looksLikePassword, "no uppercase")
        #expect(!heuristic(after: "ABC123").looksLikePassword, "no lowercase")
    }

    @Test func shortMixedRunsAreNotPasswords() {
        #expect(!heuristic(after: "Ab1").looksLikePassword)
    }

    @Test func digitsCountTowardLengthEvenThoughTheyAreNotBuffered() {
        // The bug this guards: length used to be counted from the letter buffer, which
        // digits never enter, so a password like "Ab12cd" measured as 4 characters.
        let heuristic = heuristic(after: "Ab12cd")
        #expect(heuristic.printableCount == 6)
        #expect(heuristic.looksLikePassword)
    }

    @Test func nonPrintableKeysAreIgnored() {
        var heuristic = PasswordHeuristic()
        heuristic.record(keycode: KeyMapping.spaceKeycode, isShifted: false)
        heuristic.record(keycode: KeyMapping.backspaceKeycode, isShifted: false)
        #expect(heuristic.printableCount == 0)
    }

    @Test func backspaceShortensTheRun() {
        var heuristic = heuristic(after: "Ab12cd")
        #expect(heuristic.looksLikePassword)
        heuristic.removeLast()
        #expect(!heuristic.looksLikePassword, "should fall under the length floor")
        #expect(heuristic.printableCount == 5)
    }

    @Test func removeLastDoesNotGoNegative() {
        var heuristic = PasswordHeuristic()
        heuristic.removeLast()
        heuristic.removeLast()
        #expect(heuristic.printableCount == 0)
    }

    @Test func resetClearsEverything() {
        var heuristic = heuristic(after: "Passw1")
        heuristic.reset()
        #expect(!heuristic.looksLikePassword)
        #expect(heuristic.printableCount == 0)
    }
}
