import Foundation

/// Character pairs that never occur in English or Ukrainian words.
///
/// The detector treats a hit as evidence that the user is typing in the wrong layout, so
/// a pair listed here that actually occurs in a real word pushes correct typing toward
/// being rewritten. `ProtoLanguageTests` enforces the invariant that no listed pair
/// appears anywhere in the bundled dictionaries — the earlier hand-written lists violated
/// it 183 times in English alone ("three", "wisdom", "six", "adjust", "excellent"...).
///
/// When adding a pair, run the tests: the corpus is the arbiter. Note the corpus can only
/// disprove a pair, never confirm one — a few entries were also removed by hand because
/// they are ordinary Ukrainian ("цю", "гт" as in "нігті", "зш" as in "зшити") that the
/// 50k word list simply does not happen to cover.
struct ProtoLanguage {

    // MARK: - English Impossible Bigrams

    /// Two-character sequences that never occur in English words.
    /// Almost all involve q, j, x, z or v followed by another consonant.
    /// Removed by hand despite passing the corpus test: "gz" (zigzag),
    /// "zv" (rendezvous) — real words the 50k list happens not to contain.
    static let englishImpossibleBigrams: Set<String> = [
        "bq", "cj", "cx", "fq", "gq", "gx", "hx", "jb", "jf", "jk", "jq",
        "jv", "jx", "jz", "kj", "kq", "kx", "kz", "mq", "pz", "qb", "qc", "qf",
        "qg", "qj", "qk", "qx", "qz", "sx", "tq", "vf", "vj", "vk", "vm", "vq",
        "vx", "wq", "wx", "xj", "xk", "xn", "xq", "xz", "zf", "zk", "zq",
        "zx",
    ]

    // MARK: - Ukrainian Impossible Bigrams

    /// Two-character sequences that never occur in Ukrainian words,
    /// based on Ukrainian phonotactic and orthographic rules.
    static let ukrainianImpossibleBigrams: Set<String> = [
        // ї never follows a consonant directly — it needs a vowel, an apostrophe,
        // or word start before it.
        "бї", "вї", "гї", "дї", "жї", "зї", "кї", "лї", "мї", "нї", "пї", "рї",
        "сї", "тї", "фї", "хї", "цї", "чї", "шї", "щї", "ґї",
        // є and ю after hushing consonants and ц — these take е and у instead.
        "жє", "хє", "цє", "чє", "шє", "щє", "ґє",
        "жю", "хю", "чю", "шю", "щю", "ґю",
        // щ followed by another consonant.
        "щб", "щг", "щд", "щж", "щз", "щк", "щл", "щм", "щп", "щр", "щс", "щт",
        "щф", "щх", "щц", "щч", "щш", "щщ", "щґ",
        // ь followed by a vowel other than о, and doubled ь. "ьє" is NOT here:
        // it occurs in loanwords (досьє, ательє, портьє, круп'є).
        "ьа", "ье", "ьи", "ьу", "ьі", "ьї", "ьґ", "ьь",
        // ґ is rare and combines with almost no consonant.
        "ґб", "ґг", "ґд", "ґж", "ґк", "ґм", "ґп", "ґс", "ґт", "ґф", "ґх", "ґц",
        "ґч", "ґш", "ґщ",
        // ф is rare in native words and does not cluster with these. "фк" is NOT
        // here: it occurs in diminutives (шафка).
        "фд", "фж", "фз", "фм", "фп", "фх", "фц", "фш", "фщ", "фґ", "гф",
        // ж and з clusters that do not occur. "зщ" is NOT here: it occurs across
        // the prefix boundary (розщеплення, безщасний).
        "жп", "жт", "жф", "жх", "жш", "жщ",
        // Doubled consonants that never occur.
        "хх",
    ]

    // MARK: - Public API

    /// Check if a word contains any impossible bigram for the given language
    static func hasImpossibleBigram(_ word: String, language: Language) -> Bool {
        switch language {
        case .english: return hasImpossibleEnglishBigram(word)
        case .ukrainian: return hasImpossibleUkrainianBigram(word)
        // No bundled Russian corpus, so no list: the corpus is the arbiter of every pair
        // above, and an unverified list would push correct typing toward being rewritten.
        case .russian: return false
        }
    }

    /// Check if text could belong to the given language (right script, no impossible pairs)
    static func couldBe(_ word: String, language: Language) -> Bool {
        switch language {
        case .english: return couldBeEnglish(word)
        case .ukrainian: return couldBeUkrainian(word)
        case .russian: return usesScript(word, of: .russian)
        }
    }

    /// Check if a word contains any impossible bigrams for English
    static func hasImpossibleEnglishBigram(_ word: String) -> Bool {
        contains(word, anyOf: englishImpossibleBigrams)
    }

    /// Check if a word contains any impossible bigrams for Ukrainian
    static func hasImpossibleUkrainianBigram(_ word: String) -> Bool {
        contains(word, anyOf: ukrainianImpossibleBigrams)
    }

    private static func contains(_ word: String, anyOf bigrams: Set<String>) -> Bool {
        let chars = Array(word.lowercased())
        guard chars.count >= 2 else { return false }
        for i in 0..<(chars.count - 1) {
            if bigrams.contains(String(chars[i]) + String(chars[i + 1])) {
                return true
            }
        }
        return false
    }

    /// Whether every character belongs to the language's own alphabet.
    ///
    /// Worth checking before consulting a spell checker, which strips punctuation and so
    /// calls ",elm" a correctly spelled English word on the strength of "elm". The buffer
    /// really does contain punctuation: several US-layout punctuation keys are Ukrainian
    /// letters, so "будь" arrives as ",elm".
    static func usesScript(_ word: String, of language: Language) -> Bool {
        let lower = word.lowercased()
        guard !lower.isEmpty else { return false }
        switch language {
        case .english:
            return lower.allSatisfy { $0.isASCII && $0.isLetter }
        case .ukrainian, .russian:
            // The apostrophe is part of Ukrainian orthography (м'ясо, ім'я, комп'ютер) —
            // typewriter ', right quote ', and modifier letter ʼ all occur in real text.
            // Requiring pure Cyrillic here made every apostrophized word invisible to the
            // system dictionary. At least one Cyrillic letter is still required, so a
            // bare apostrophe run cannot pass as Ukrainian.
            var hasCyrillic = false
            for char in lower {
                guard let scalar = char.unicodeScalars.first else { return false }
                if (0x0400...0x04FF).contains(scalar.value) {
                    hasCyrillic = true
                } else if scalar.value != 0x27 && scalar.value != 0x2019 && scalar.value != 0x02BC {
                    return false
                }
            }
            return hasCyrillic
        }
    }

    /// Quick check: can this text possibly be English? (Latin script, no impossible bigrams)
    static func couldBeEnglish(_ word: String) -> Bool {
        guard usesScript(word, of: .english) else { return false }
        return !hasImpossibleEnglishBigram(word)
    }

    /// Quick check: can this text possibly be Ukrainian? (Cyrillic script, no impossible bigrams)
    static func couldBeUkrainian(_ word: String) -> Bool {
        guard usesScript(word, of: .ukrainian) else { return false }
        return !hasImpossibleUkrainianBigram(word)
    }
}
