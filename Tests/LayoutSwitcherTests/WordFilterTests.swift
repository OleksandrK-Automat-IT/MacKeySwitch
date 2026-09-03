import Testing
@testable import LayoutSwitcher

/// The filter's job is to keep the corrector away from text that only looks like a word.
/// Its risk is the mirror image: over-eager rules would silently stop correcting real
/// Ukrainian, because on a US layout several punctuation keys *are* Ukrainian letters.
@Suite struct WordFilterTests {

    @Test(arguments: ["http://example.com", "https://ok.ua", "www.google.com", "ftp.server"])
    func urlsAreSkipped(text: String) {
        #expect(WordFilter.shouldSkip(text))
    }

    @Test(arguments: ["user@example.com", "a@b", "name.surname@company.org"])
    func emailsAreSkipped(text: String) {
        #expect(WordFilter.shouldSkip(text))
    }

    @Test(arguments: ["ok.ua", "example.com", "my-site.org"])
    func bareDomainsAreSkipped(text: String) {
        #expect(WordFilter.shouldSkip(text))
    }

    @Test(arguments: ["camelCase", "myVariable", "isEnabled"])
    func identifiersAreSkipped(text: String) {
        #expect(WordFilter.shouldSkip(text))
    }

    @Test func emptyTextIsSkipped() {
        #expect(WordFilter.shouldSkip(""))
    }

    // MARK: - What must NOT be skipped

    @Test(arguments: ["hello", "three", "wisdom", "ghbdsn", "pfd;lb", "nht,f"])
    func ordinaryWordsPassThrough(text: String) {
        #expect(!WordFilter.shouldSkip(text))
    }

    @Test func ukrainianWordsEndingInYuPassThrough() {
        // "ю" is the "." key. "дякую" typed on a US layout is "lzre." — a rule that skipped
        // anything containing a dot would stop that word from ever being corrected.
        let keys = keycodes(forTyping: "lzre.")
        #expect(KeyMapping.reconstruct(keycodes: keys, language: .ukrainian) == "дякую")
        #expect(!WordFilter.shouldSkip("lzre."))
    }

    @Test func ukrainianWordsStartingWithYuPassThrough() {
        // A leading dot is not a domain either.
        #expect(!WordFilter.shouldSkip(".yfr"))
    }

    @Test(arguments: ["vf.nm", "ghfw.dfnb", "dbrjhbcnjde.nm"])
    func wrongLayoutWordsWithUnknownDomainLikeTailsPassThrough(text: String) {
        // These are real Ukrainian forms typed on US. A generic two-letter TLD rule used
        // to discard them before the dictionary could see them.
        #expect(!WordFilter.shouldSkip(text))
    }

    @Test func capitalisedWordsPassThrough() {
        // "Привіт" is "Ghbdsn" — a leading capital is not camelCase.
        #expect(!WordFilter.shouldSkip("Ghbdsn"))
        #expect(!WordFilter.shouldSkip("Hello"))
        #expect(!WordFilter.shouldSkip("HELLO"))
    }

    @Test func theFilterBarelyTouchesRealUkrainian() {
        // The filter's failure mode is silent: anything it skips is a correction that never
        // happens, with no error to notice. Measured against the shipped corpus rather than
        // argued about — a rule that starts eating real words shows up here as a number.
        let typedOnUSLayout = Corpus.ukrainian.map {
            LayoutTransliterator.convert($0, to: .english)
        }
        let skipped = typedOnUSLayout.filter { WordFilter.shouldSkip($0) }
        let rate = Double(skipped.count) / Double(max(typedOnUSLayout.count, 1))
        let examples = skipped.prefix(10).joined(separator: ", ")
        let report = "filter skips \(skipped.count) of \(typedOnUSLayout.count) real words: \(examples)"
        #expect(rate < 0.001, "\(report)")
    }
}
