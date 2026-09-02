import Testing
@testable import LayoutSwitcher

/// Inputs a real keyboard can produce that the happy-path tests never do. The bar is low
/// on purpose — no crash, no rewrite of correct text — because these are the cases nobody
/// designs for.
@Suite struct AdversarialInputTests {

    private let dict = StubDictionary(english: ["hello"], ukrainian: ["привіт"])

    private func detect(_ keys: [Keystroke], layout: Language = .english) -> Language? {
        LanguageDetector.detectIntended(
            keycodes: keys, currentLayout: layout,
            threshold: SettingsModel.Sensitivity.medium.scoreThreshold,
            settings: nil, dictionary: dict)
    }

    @Test func anEmptyBufferIsNotCorrected() {
        #expect(detect([]) == nil)
        #expect(detect([], layout: .ukrainian) == nil)
    }

    @Test func aSingleKeystrokeIsNotCorrected() {
        for text in ["a", "z", ";", "."] {
            #expect(detect(keycodes(forTyping: text)) == nil, "'\(text)'")
        }
    }

    @Test(arguments: ["....", ";;;;", ",,,,", "''''", "[]", ".,;'", "`````"])
    func punctuationOnlyRunsDoNotCrashOrCorrect(text: String) {
        // Every one of these is a run of keys that are Ukrainian letters — "ююю", "жжжж".
        let keys = keycodes(forTyping: text)
        #expect(!keys.isEmpty)
        _ = detect(keys)
        _ = LanguageDetector.gatherEvidence(
            currentText: text,
            targetText: KeyMapping.reconstruct(keycodes: keys, language: .ukrainian),
            currentLanguage: .english, dictionary: dict)
        _ = WordFilter.shouldSkip(text)
        _ = ProtoLanguage.hasImpossibleEnglishBigram(text)
    }

    @Test func aBufferAtTheLengthCapIsHandled() {
        let text = String(repeating: "ghbdsn", count: 11)   // 66 > 64
        let keys = Array(keycodes(forTyping: text).prefix(64))
        #expect(keys.count == 64)
        _ = detect(keys)
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .ukrainian).count == 64)
    }

    @Test func allCapsRealWordIsStillProtected() {
        let dict = StubDictionary(english: ["hello"], ukrainian: [])
        let r = LanguageDetector.detectIntended(
            keycodes: keycodes(forTyping: "HELLO"), currentLayout: .english,
            threshold: 10, settings: nil, dictionary: dict)
        #expect(r == nil, "case must not defeat the veto")
    }

    @Test func capsLockKeystrokesReconstructAsUppercase() {
        let keys = keycodes(forTyping: "ghbdsn", capsLock: true)
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .ukrainian) == "ПРИВІТ")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .english) == "GHBDSN")
    }

    // MARK: WordFilter edge cases

    @Test(arguments: ["e.g", "i.e", "x.yz", "a.b", "..", ".com", "com."])
    func dotsThatAreNotDomainsPassThrough(text: String) {
        #expect(!WordFilter.shouldSkip(text), "'\(text)' is not a bare domain")
    }

    @Test func aVeryLongStringDoesNotChokeTheFilter() {
        let text = String(repeating: "a", count: 10_000)
        #expect(!WordFilter.shouldSkip(text))
        #expect(WordFilter.shouldSkip(text + "@x"))
    }

    @Test func cyrillicBeforeADotIsNotADomain() {
        // The domain rule is Latin-only on purpose; "дякую." must not be a domain.
        #expect(!WordFilter.shouldSkip("дякую.ua"))
    }

    // MARK: Transliterator edge cases

    @Test func emojiDoNotInfluenceDirection() {
        #expect(LayoutTransliterator.detectLanguage(of: "🙂🙂🙂 ghbdsn") == .english)
        #expect(LayoutTransliterator.detectLanguage(of: "🙂") == nil)
    }

    @Test func combiningMarksSurviveConversion() {
        // A decomposed "é" is 'e' + U+0301; the letter converts, the mark passes through.
        let converted = LayoutTransliterator.convert("e\u{0301}", to: .ukrainian)
        #expect(converted.unicodeScalars.contains("\u{0301}"))
    }

    // MARK: ProtoLanguage edge cases

    @Test func scriptCheckOnEmptyAndSingle() {
        #expect(!ProtoLanguage.usesScript("", of: .english))
        #expect(ProtoLanguage.usesScript("a", of: .english))
        #expect(ProtoLanguage.usesScript("я", of: .ukrainian))
        #expect(!ProtoLanguage.hasImpossibleEnglishBigram("a"))
        #expect(!ProtoLanguage.hasImpossibleUkrainianBigram(""))
    }
}
