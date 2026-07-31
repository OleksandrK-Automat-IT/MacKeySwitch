import Testing
@testable import LayoutSwitcher

/// The "impossible bigram" lists are hand-written linguistic guesses, and the detector
/// treats a hit as evidence that the user is in the wrong layout. A pair that occurs in
/// the app's own dictionary is therefore not merely imprecise — it is self-contradictory,
/// and it pushes real words toward being rewritten. These tests hold the lists to the
/// shipped corpus.
@Suite struct ProtoLanguageTests {

    private func violations(
        in words: [String],
        against bigrams: Set<String>
    ) -> [(bigram: String, example: String)] {
        var found: [String: String] = [:]
        for word in words {
            let chars = Array(word)
            guard chars.count >= 2 else { continue }
            for i in 0..<(chars.count - 1) {
                let bigram = String(chars[i]) + String(chars[i + 1])
                if bigrams.contains(bigram), found[bigram] == nil {
                    found[bigram] = word
                }
            }
        }
        return found.sorted { $0.key < $1.key }.map { (bigram: $0.key, example: $0.value) }
    }

    @Test func corpusIsAvailable() {
        #expect(Corpus.english.count > 1000)
        #expect(Corpus.ukrainian.count > 1000)
    }

    @Test func noEnglishImpossibleBigramOccursInTheEnglishDictionary() {
        let bad = violations(in: Corpus.english, against: ProtoLanguage.englishImpossibleBigrams)
        let report = bad.map { "\($0.bigram) (\($0.example))" }.joined(separator: ", ")
        #expect(bad.isEmpty, "\(bad.count) bigrams occur in real words: \(report)")
    }

    @Test func noUkrainianImpossibleBigramOccursInTheUkrainianDictionary() {
        let bad = violations(in: Corpus.ukrainian, against: ProtoLanguage.ukrainianImpossibleBigrams)
        let report = bad.map { "\($0.bigram) (\($0.example))" }.joined(separator: ", ")
        #expect(bad.isEmpty, "\(bad.count) bigrams occur in real words: \(report)")
    }

    @Test(arguments: ["three", "wisdom", "months", "vodka", "adjust", "advance", "six",
                      "breakfast", "bookmark", "excellent", "crowd", "hawk", "anxious",
                      "banquet", "football", "output", "comfort", "napkin", "fjord",
                      "highball", "withdraw", "highway", "czar", "marquee", "headquarters"])
    func commonEnglishWordsAreNotFlaggedAsImpossible(word: String) {
        #expect(!ProtoLanguage.hasImpossibleEnglishBigram(word))
    }

    @Test func scriptCheckRejectsWrongAlphabet() {
        #expect(!ProtoLanguage.couldBe("привіт", language: .english))
        #expect(!ProtoLanguage.couldBe("hello", language: .ukrainian))
        #expect(ProtoLanguage.couldBe("hello", language: .english))
        #expect(ProtoLanguage.couldBe("привіт", language: .ukrainian))
    }
}
