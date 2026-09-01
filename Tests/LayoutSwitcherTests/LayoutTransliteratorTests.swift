import Testing
@testable import LayoutSwitcher

/// Selection correction has no keycodes to work from — only the characters on screen — so
/// everything depends on the character mapping being an exact mirror of the typing path.
@Suite struct LayoutTransliteratorTests {

    @Test func convertsWholeWordsBetweenLayouts() {
        #expect(LayoutTransliterator.convert("ghbdsn", to: .ukrainian) == "привіт")
        #expect(LayoutTransliterator.convert("привіт", to: .english) == "ghbdsn")
    }

    @Test func matchesWhatTheTypingPathWouldProduce() {
        // The two paths must not drift: transliterating the on-screen text has to give the
        // same answer as reconstructing the keystrokes that produced it.
        for typed in ["ghbdsn", "pfd;lb", "hello", "nht,f", "lzre."] {
            let keys = keycodes(forTyping: typed)
            let viaKeycodes = KeyMapping.reconstruct(keycodes: keys, language: .ukrainian)
            let viaCharacters = LayoutTransliterator.convert(typed, to: .ukrainian)
            #expect(viaKeycodes == viaCharacters, "'\(typed)' disagrees between the two paths")
        }
    }

    @Test func roundTripsBackToTheOriginal() {
        for text in ["ghbdsn", "pfd;lb", "hello world"] {
            let there = LayoutTransliterator.convert(text, to: .ukrainian)
            #expect(LayoutTransliterator.convert(there, to: .english) == text)
        }
    }

    @Test func punctuationThatIsALetterConverts() {
        // ';' is 'ж', ',' is 'б', '.' is 'ю' — these must convert, not pass through.
        #expect(LayoutTransliterator.convert(";", to: .ukrainian) == "ж")
        #expect(LayoutTransliterator.convert(",", to: .ukrainian) == "б")
        #expect(LayoutTransliterator.convert(".", to: .ukrainian) == "ю")
    }

    @Test func unmappedCharactersSurvive() {
        // Spaces, digits and anything exotic keep a sentence's shape intact.
        #expect(LayoutTransliterator.convert("ghbdsn 42!", to: .ukrainian) == "привіт 42!")
        #expect(LayoutTransliterator.convert("🙂", to: .ukrainian) == "🙂")
        #expect(LayoutTransliterator.convert("", to: .ukrainian) == "")
    }

    @Test func preservesCase() {
        #expect(LayoutTransliterator.convert("Ghbdsn", to: .ukrainian) == "Привіт")
        #expect(LayoutTransliterator.convert("Привіт", to: .english) == "Ghbdsn")
    }

    // MARK: - Direction

    @Test func detectsTheDominantScript() {
        #expect(LayoutTransliterator.detectLanguage(of: "ghbdsn") == .english)
        #expect(LayoutTransliterator.detectLanguage(of: "привіт") == .ukrainian)
    }

    @Test func ignoresCharactersThatBelongToNeitherLayout() {
        // A selection that starts with a quote or digit must still be classified by its
        // letters, not by its first character.
        #expect(LayoutTransliterator.detectLanguage(of: "\"ghbdsn\" 42") == .english)
        #expect(LayoutTransliterator.detectLanguage(of: "42 привіт!") == .ukrainian)
    }

    @Test func refusesToGuessOnAnEvenMix() {
        // Converting a genuinely mixed selection would corrupt whichever half was correct.
        #expect(LayoutTransliterator.detectLanguage(of: "abвг") == nil)
        #expect(LayoutTransliterator.detectLanguage(of: "") == nil)
        #expect(LayoutTransliterator.detectLanguage(of: "12345") == nil)
    }

    @Test func aMajorityDecidesAMixedSelection() {
        #expect(LayoutTransliterator.detectLanguage(of: "hello вг") == .english)
        #expect(LayoutTransliterator.detectLanguage(of: "привіт ab") == .ukrainian)
    }
}
