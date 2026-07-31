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

    @Test func languageOppositeRoundTrips() {
        #expect(Language.english.opposite == .ukrainian)
        #expect(Language.ukrainian.opposite == .english)
        #expect(Language.english.opposite.opposite == .english)
    }
}
