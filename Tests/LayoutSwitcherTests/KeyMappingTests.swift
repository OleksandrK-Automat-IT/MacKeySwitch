import Testing
@testable import LayoutSwitcher

@Suite struct KeyMappingTests {

    @Test func reconstructsBothLayoutsFromTheSameKeystrokes() {
        let keys = keycodes(forTyping: "ghbdsn")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .english) == "ghbdsn")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .ukrainian) == "привіт")
    }

    @Test func shiftProducesUppercaseInBothLayouts() {
        let keys = keycodes(forTyping: "Hello")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .english) == "Hello")
        let ukrainian = KeyMapping.reconstruct(keycodes: keys, language: .ukrainian)
        #expect(ukrainian.first == "Р")
        #expect(ukrainian.count == 5)
    }

    @Test func unmappedKeycodesAreSkippedRatherThanCrashing() {
        #expect(KeyMapping.reconstruct(keycodes: [(0xFF, false)], language: .english) == "")
        #expect(KeyMapping.reconstruct(keycodes: [], language: .english) == "")
    }

    @Test func everyLetterKeyMapsToBothLanguages() {
        for keycode in KeyMapping.unshifted.keys where KeyMapping.isLetterKey(keycode) {
            #expect(KeyMapping.unshifted[keycode] != nil)
            #expect(KeyMapping.shifted[keycode] != nil, "keycode \(keycode) has no shifted pair")
        }
    }

    @Test func returnAndTabEndAWordButDoNotTriggerACorrection() {
        // A correction runs ~150ms after the boundary key already went through: by then
        // Return has sent the message and Tab has moved focus, so replaying the word would
        // type into the wrong place.
        let returnKey: UInt16 = 0x24
        let tabKey: UInt16 = 0x30

        #expect(KeyMapping.wordBoundaryKeycodes.contains(returnKey))
        #expect(KeyMapping.wordBoundaryKeycodes.contains(tabKey))
        #expect(!KeyMapping.correctionTriggerKeycodes.contains(returnKey))
        #expect(!KeyMapping.correctionTriggerKeycodes.contains(tabKey))
        #expect(KeyMapping.correctionTriggerKeycodes.contains(KeyMapping.spaceKeycode))
    }

    @Test func correctionTriggersAreAlsoWordBoundaries() {
        #expect(KeyMapping.correctionTriggerKeycodes.isSubset(of: KeyMapping.wordBoundaryKeycodes))
    }

    @Test func numberRowIsNotBufferedAsLetters() {
        // Password detection reads the number row separately precisely because these keys
        // are excluded from the reconstruction buffer.
        for keycode in KeyMapping.numberRowKeycodes {
            #expect(!KeyMapping.isLetterKey(keycode), "keycode \(keycode) counted as a letter")
        }
    }

    @Test func numberRowShiftedProducesSymbolsNotLetters() {
        // The password heuristic treats a shifted number-row key as a symbol. That only
        // holds if these keycodes are the digit row on a US layout.
        for keycode in KeyMapping.numberRowKeycodes {
            let unshifted = KeyMapping.unshifted[keycode]
            #expect(unshifted?.en.isNumber == true, "keycode \(keycode) is not a digit")
        }
    }

    @Test(arguments: ["pfd;lb", "ghbdsn", "hello", "j,'.", "gjckfyysq"])
    func everyBufferedKeystrokeIsExactlyOneCharacterInBothLayouts(typed: String) {
        // The correction erases the old word with a fixed number of backspaces, and that
        // count comes from the reconstructed text. It is only correct if one keystroke
        // never yields two characters, or none, in either layout.
        let keys = keycodes(forTyping: typed)
        #expect(keys.count == typed.count, "helper dropped a key from '\(typed)'")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .english).count == keys.count)
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .ukrainian).count == keys.count)
    }

    @Test func keysThatTypePunctuationInEnglishAreUkrainianLetters() {
        // Why the correction cannot delete by "select word backward": these keys are part
        // of a Ukrainian word but read as punctuation, and a text engine treats punctuation
        // as a word break. "pfd;lb" is "завжди"; selecting backward stops at the ';'.
        let punctuationKeys: [(UInt16, Character, Character)] = [
            (0x29, ";", "ж"),
            (0x2B, ",", "б"),
            (0x2F, ".", "ю"),
            (0x27, "'", "є"),
            (0x21, "[", "х"),
            (0x1E, "]", "ї"),
        ]
        for (keycode, english, ukrainian) in punctuationKeys {
            #expect(KeyMapping.isLetterKey(keycode), "keycode \(keycode) must be buffered")
            #expect(KeyMapping.unshifted[keycode]?.en == english)
            #expect(KeyMapping.unshifted[keycode]?.ua == ukrainian)
        }
    }

    @Test func theReportedMiscorrectionReconstructsCorrectly() {
        // Regression for "pfd;lb" being corrected to "pfd;завжди" instead of "завжди".
        let keys = keycodes(forTyping: "pfd;lb")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .ukrainian) == "завжди")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .english) == "pfd;lb")
    }

    @Test func languageOppositeRoundTrips() {
        #expect(Language.english.opposite == .ukrainian)
        #expect(Language.ukrainian.opposite == .english)
        #expect(Language.english.opposite.opposite == .english)
    }
}
