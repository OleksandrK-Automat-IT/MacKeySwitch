import Foundation
import Testing
@testable import LayoutSwitcher

/// Guards the data-generation contract, not just a minimum file size. The previous files
/// contained 50,000 mostly short words and duplicates while omitting everyday vocabulary.
@Suite struct FrequencyDictionaryTests {

    @Test func dictionariesAreCompleteUniqueAndFrequencyRanked() {
        #expect(Corpus.english.count == 100_000)
        #expect(Corpus.ukrainian.count == 100_000)
        #expect(Corpus.russian.count == 100_000)
        #expect(Set(Corpus.english).count == Corpus.english.count)
        #expect(Set(Corpus.ukrainian).count == Corpus.ukrainian.count)
        #expect(Set(Corpus.russian).count == Corpus.russian.count)
        #expect(Array(Corpus.english.prefix(3)) == ["the", "to", "and"])
        #expect(Array(Corpus.ukrainian.prefix(3)) == ["в", "на", "не"])
        #expect(Array(Corpus.russian.prefix(3)) == ["в", "и", "на"])
        #expect(Corpus.english.contains { $0.count > 15 })
        #expect(Corpus.ukrainian.contains { $0.count > 12 })
        #expect(Corpus.russian.contains { $0.count > 12 })
    }

    @Test func reviewedCoreVocabularyIsBundled() {
        for word in ["hello", "thanks", "wisdom", "computer", "keyboard", "application",
                     "correction", "settings", "tomorrow", "language", "dictionary"] {
            #expect(Corpus.english.contains(word), "missing English core word: \(word)")
        }
        for word in ["привіт", "дякую", "добре", "зробити", "сьогодні", "питання",
                     "клавіатура", "програма", "виправлення", "налаштування", "словник"] {
            #expect(Corpus.ukrainian.contains(word), "missing Ukrainian core word: \(word)")
        }
        for word in ["привет", "спасибо", "хорошо", "сегодня", "вопрос", "пожалуйста",
                     "клавиатура", "компьютер", "настройки", "исправление", "словарь"] {
            #expect(Corpus.russian.contains(word), "missing Russian core word: \(word)")
        }
    }

    @Test func everyBundledEntryIsAUsableWordForItsLanguage() {
        let badEnglish = Corpus.english.filter {
            !DictionaryManager.isValidImportedWord($0, language: .english)
        }
        let badUkrainian = Corpus.ukrainian.filter {
            !DictionaryManager.isValidImportedWord($0, language: .ukrainian)
        }
        let badRussian = Corpus.russian.filter {
            !DictionaryManager.isValidImportedWord($0, language: .russian)
        }
        #expect(badEnglish.isEmpty, "invalid English entries: \(badEnglish.prefix(10))")
        #expect(badUkrainian.isEmpty, "invalid Ukrainian entries: \(badUkrainian.prefix(10))")
        #expect(badRussian.isEmpty, "invalid Russian entries: \(badRussian.prefix(10))")
    }

    @Test func attributionNoticeShipsAsAResource() {
        #expect(ResourceBundle.url(forResource: "DICTIONARY-NOTICES", extension: "md") != nil)
    }
}
