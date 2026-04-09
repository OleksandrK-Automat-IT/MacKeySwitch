import Foundation

struct LanguageDetector {
    // Common English words (lowercase)
    static let englishWords: Set<String> = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "i",
        "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
        "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
        "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
        "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
        "when", "make", "can", "like", "time", "no", "just", "him", "know", "take",
        "people", "into", "year", "your", "good", "some", "could", "them", "see", "other",
        "than", "then", "now", "look", "only", "come", "its", "over", "think", "also",
        "back", "after", "use", "two", "how", "our", "work", "first", "well", "way",
        "even", "new", "want", "because", "any", "these", "give", "day", "most", "us",
        "is", "are", "was", "were", "been", "has", "had", "did", "does", "am",
        "let", "may", "should", "must", "shall", "here", "where", "why", "yes", "no",
        "while", "each", "made", "find", "more", "long", "very", "after", "before", "much",
        "still", "between", "own", "under", "never", "last", "few", "same", "another", "name",
        "please", "help", "hello", "world", "test", "file", "code", "data", "home", "page",
        "open", "close", "save", "delete", "create", "update", "start", "stop", "run", "end",
        "true", "false", "null", "void", "class", "func", "var", "let", "const", "return",
        "import", "export", "public", "private", "static", "final", "switch", "case", "break",
        "error", "warning", "info", "debug", "system", "user", "admin", "server", "client",
        "table", "select", "from", "where", "insert", "value", "key", "index", "type",
    ]

    // Common Ukrainian words (lowercase)
    static let ukrainianWords: Set<String> = [
        "і", "в", "не", "на", "що", "з", "як", "це", "до", "та",
        "у", "він", "я", "його", "за", "від", "але", "вона", "все", "вже",
        "ми", "той", "бути", "ще", "по", "так", "було", "при", "їх", "тут",
        "ні", "коли", "їй", "мене", "тому", "вони", "був", "час", "для", "через",
        "може", "дуже", "треба", "тоді", "можна", "без", "якщо", "нам", "нас", "лише",
        "або", "між", "після", "себе", "також", "свій", "перед", "день", "під", "над",
        "рік", "раз", "їм", "ось", "саме", "чи", "там", "тепер", "навіть", "менше",
        "навколо", "більше", "добре", "потім", "один", "два", "три", "перший", "новий",
        "великий", "людина", "людей", "дім", "місто", "робота", "слово", "справа", "життя",
        "країна", "друг", "рука", "місце", "голова", "кінець", "питання", "стати", "знати",
        "хочу", "думати", "говорити", "йти", "дати", "мати", "зробити", "працювати", "взяти",
        "привіт", "добрий", "ранок", "вечір", "дякую", "будь", "ласка", "так", "ні",
        "який", "яка", "яке", "які", "цей", "ця", "ці", "той", "та", "ті",
        "де", "куди", "звідки", "чому", "скільки", "хто", "що", "як", "коли",
        "дуже", "багато", "мало", "завжди", "ніколи", "часто", "іноді", "зараз", "потім",
    ]

    // Common English bigrams
    static let englishBigrams: Set<String> = [
        "th", "he", "in", "er", "an", "re", "on", "at", "en", "nd",
        "ti", "es", "or", "te", "of", "ed", "is", "it", "al", "ar",
        "st", "to", "nt", "ng", "se", "ha", "as", "ou", "io", "le",
        "ve", "co", "me", "de", "hi", "ri", "ro", "ic", "ne", "ea",
        "ra", "ce", "li", "ch", "ll", "be", "ma", "si", "om", "ur",
    ]

    // Common Ukrainian bigrams
    static let ukrainianBigrams: Set<String> = [
        "на", "но", "ні", "не", "ра", "ро", "ре", "ри", "ів", "ій",
        "ст", "та", "то", "ти", "те", "пр", "по", "пе", "ко", "ка",
        "ку", "ві", "во", "ва", "за", "зн", "ла", "ло", "ли", "ле",
        "да", "до", "де", "ди", "ми", "мо", "ма", "ме", "ен", "ер",
        "ал", "ан", "ор", "от", "об", "ос", "ів", "ін", "іс", "ій",
        "го", "ге", "ся", "сь", "ть", "чи", "че", "що", "як", "юч",
    ]

    /// Score a word for how likely it is English (higher = more likely EN)
    static func scoreEnglish(_ word: String) -> Double {
        let lower = word.lowercased()
        var score: Double = 0

        // All characters are Latin
        let isLatin = lower.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if !isLatin { return -100 }

        // Dictionary match
        if englishWords.contains(lower) {
            score += 50
        }

        // Bigram analysis
        if lower.count >= 2 {
            let chars = Array(lower)
            var bigramHits = 0
            for i in 0..<(chars.count - 1) {
                let bigram = String(chars[i...i+1])
                if englishBigrams.contains(bigram) {
                    bigramHits += 1
                }
            }
            let bigramRatio = Double(bigramHits) / Double(chars.count - 1)
            score += bigramRatio * 20
        }

        // Vowel/consonant ratio check — English words typically have vowels
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        let vowelCount = lower.filter { vowels.contains($0) }.count
        let ratio = lower.isEmpty ? 0 : Double(vowelCount) / Double(lower.count)
        if ratio > 0.15 && ratio < 0.7 {
            score += 5
        }

        return score
    }

    /// Score a word for how likely it is Ukrainian (higher = more likely UA)
    static func scoreUkrainian(_ word: String) -> Double {
        let lower = word.lowercased()
        var score: Double = 0

        // All characters are Cyrillic (Ukrainian range)
        let isCyrillic = lower.allSatisfy { char in
            guard let scalar = char.unicodeScalars.first else { return false }
            let v = scalar.value
            // Basic Cyrillic: U+0400–U+04FF, covers Ukrainian specific chars
            return (v >= 0x0400 && v <= 0x04FF)
        }
        if !isCyrillic { return -100 }

        // Dictionary match
        if ukrainianWords.contains(lower) {
            score += 50
        }

        // Bigram analysis
        if lower.count >= 2 {
            let chars = Array(lower)
            var bigramHits = 0
            for i in 0..<(chars.count - 1) {
                let bigram = String(chars[i...i+1])
                if ukrainianBigrams.contains(bigram) {
                    bigramHits += 1
                }
            }
            let bigramRatio = Double(bigramHits) / Double(chars.count - 1)
            score += bigramRatio * 20
        }

        // Ukrainian-specific characters boost
        let uaSpecific: Set<Character> = ["і", "ї", "є", "ґ"]
        if lower.contains(where: { uaSpecific.contains($0) }) {
            score += 10
        }

        return score
    }

    /// Determine which language a word most likely belongs to.
    /// Returns nil if unclear or both score low.
    static func detectLanguage(of word: String) -> Language? {
        let enScore = scoreEnglish(word)
        let uaScore = scoreUkrainian(word)

        // Need a meaningful difference to trigger switch
        let threshold: Double = 5.0

        if enScore > uaScore + threshold && enScore > 0 {
            return .english
        }
        if uaScore > enScore + threshold && uaScore > 0 {
            return .ukrainian
        }

        return nil
    }

    /// Given buffered keycodes, reconstruct both EN and UA versions,
    /// and determine the intended language.
    static func detectIntended(keycodes: [(UInt16, Bool)], currentLayout: Language) -> Language? {
        let enWord = KeyMapping.reconstruct(keycodes: keycodes, language: .english)
        let uaWord = KeyMapping.reconstruct(keycodes: keycodes, language: .ukrainian)

        let enScore = scoreEnglish(enWord)
        let uaScore = scoreUkrainian(uaWord)

        // Only switch if the OTHER language scores significantly better
        let threshold: Double = 10.0

        switch currentLayout {
        case .english:
            // Currently typing in English. If Ukrainian version scores much better, switch
            if uaScore > enScore + threshold && uaScore > 0 {
                return .ukrainian
            }
        case .ukrainian:
            // Currently typing in Ukrainian. If English version scores much better, switch
            if enScore > uaScore + threshold && enScore > 0 {
                return .english
            }
        }

        return nil
    }
}
