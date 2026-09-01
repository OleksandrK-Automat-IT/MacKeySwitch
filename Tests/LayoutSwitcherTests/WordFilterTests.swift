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

    @Test func capitalisedWordsPassThrough() {
        // "Привіт" is "Ghbdsn" — a leading capital is not camelCase.
        #expect(!WordFilter.shouldSkip("Ghbdsn"))
        #expect(!WordFilter.shouldSkip("Hello"))
        #expect(!WordFilter.shouldSkip("HELLO"))
    }
}
