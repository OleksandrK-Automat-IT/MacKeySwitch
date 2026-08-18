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
        #expect(KeyMapping.reconstruct(keycodes: [Keystroke(keycode: 0xFF)], language: .english) == "")
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

    // MARK: - Caps Lock

    @Test func capsLockUppercasesLettersInBothLayouts() {
        // Regression: the buffer recorded only Shift, so anything typed with Caps Lock on
        // was retyped in lowercase — "ПРИВІТ" came back as "привіт".
        let keys = keycodes(forTyping: "ghbdsn", capsLock: true)
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .english) == "GHBDSN")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .ukrainian) == "ПРИВІТ")
    }

    @Test func shiftWithCapsLockTypesLowercase() {
        // The macOS convention: Caps Lock inverts, so Shift on top of it is lowercase.
        let keys = keycodes(forTyping: "GHBDSN", capsLock: true)
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .english) == "ghbdsn")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .ukrainian) == "привіт")
    }

    @Test func capsLockLeavesPunctuationAlone() {
        // ';' is not a letter in English but *is* one ('ж') in Ukrainian, so a single
        // "shifted" flag could never have described this keystroke correctly.
        let stroke = Keystroke(keycode: 0x29, shift: false, capsLock: true)
        #expect(KeyMapping.character(for: stroke, language: .english) == ";")
        #expect(KeyMapping.character(for: stroke, language: .ukrainian) == "Ж")
    }

    @Test(arguments: [false, true])
    func everyKeystrokeIsExactlyOneCharacterWhateverTheModifiers(capsLock: Bool) {
        // The backspace count depends on this holding for every key in the map, in every
        // modifier combination — a two-character expansion would misplace the caret.
        for keycode in KeyMapping.unshifted.keys {
            for shift in [false, true] {
                let stroke = Keystroke(keycode: keycode, shift: shift, capsLock: capsLock)
                for language in Language.allCases {
                    guard let char = KeyMapping.character(for: stroke, language: language) else {
                        continue
                    }
                    #expect(String(char).count == 1)
                }
            }
        }
    }

    // MARK: - Buffer / screen correspondence

    @Test func keysThatPrintWithoutBufferingAreNotLetterKeys() {
        // These print a character that `reconstruct` cannot produce, so the monitor has to
        // empty the buffer when it sees one. If any of them were ever added to the letter
        // set without a matching map entry, the backspace count would silently drift.
        // (keycodes: '-', '=', '\', '/', and the digit row.)
        let printableButUnbuffered = Set<UInt16>([0x1B, 0x18, 0x2A, 0x2C])
            .union(KeyMapping.numberRowKeycodes)
        for keycode in printableButUnbuffered {
            #expect(!KeyMapping.isLetterKey(keycode), "keycode \(keycode) must not be buffered")
        }
    }

    @Test func caretMovingKeysAreNeitherBufferedNorWordBoundaries() {
        // Which puts them on the monitor's "empty the buffer" path. Before that path
        // existed they fell through untouched, so typing "ghbd", pressing Left twice and
        // typing "sn" left the buffer claiming a six-character run that was no longer the
        // text in front of the caret — and the correction's backspaces ate whatever was.
        let caretMovers: [(UInt16, String)] = [
            (0x7B, "left"), (0x7C, "right"), (0x7D, "down"), (0x7E, "up"),
            (0x73, "home"), (0x77, "end"), (0x74, "page up"), (0x79, "page down"),
            (0x75, "forward delete"), (0x35, "escape"),
        ]
        for (keycode, name) in caretMovers {
            #expect(!KeyMapping.isLetterKey(keycode), "\(name) must not be buffered")
            #expect(!KeyMapping.wordBoundaryKeycodes.contains(keycode),
                    "\(name) must not be treated as a word boundary")
        }
    }

    @Test func everyBufferedKeyHasAMapEntryForBothModifierStates() {
        // The other half of the same invariant: a buffered key with no map entry would be
        // dropped by `reconstruct`, making the count one short.
        for keycode in KeyMapping.unshifted.keys where KeyMapping.isLetterKey(keycode) {
            #expect(KeyMapping.character(for: Keystroke(keycode: keycode), language: .english) != nil)
            #expect(KeyMapping.character(for: Keystroke(keycode: keycode, shift: true),
                                         language: .ukrainian) != nil)
        }
    }

    @Test func languageOppositeRoundTrips() {
        #expect(Language.english.opposite == .ukrainian)
        #expect(Language.ukrainian.opposite == .english)
        #expect(Language.english.opposite.opposite == .english)
    }
}
