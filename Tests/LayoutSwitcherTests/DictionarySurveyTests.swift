import Testing
import Foundation
@testable import LayoutSwitcher

@Suite struct DictionarySurveyTests {

    private func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("survey-\(UUID().uuidString).txt")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func itNamesTheLanguageOfACleanList() throws {
        let english = try file(["hello", "world", "wisdom", "three"])
        let ukrainian = try file(["привіт", "завжди", "їжак", "ґанок"])
        let russian = try file(["привет", "ёлка", "объезд", "мышь"])
        defer { for u in [english, ukrainian, russian] { try? FileManager.default.removeItem(at: u) } }

        #expect(DictionaryManager.survey(url: english)?.detected == .english)
        #expect(DictionaryManager.survey(url: ukrainian)?.detected == .ukrainian)
        #expect(DictionaryManager.survey(url: russian)?.detected == .russian)
    }

    @Test func theBundledListsAreNamedCorrectly() throws {
        // The real thing, not a handful of hand-picked words: a large list carries loanwords,
        // abbreviations and proper nouns, and detection has to survive them.
        for (resource, expected) in [("en_words", Language.english), ("ua_words", .ukrainian)] {
            let url = try #require(ResourceBundle.url(forResource: resource, extension: "txt"))
            let survey = try #require(DictionaryManager.survey(url: url))
            #expect(survey.detected == expected, "\(resource)")
            #expect(survey.totalUsable > 40_000, "\(resource)")
        }
    }

    @Test func aMixedFileRefusesToGuess() throws {
        // Half Latin, half Cyrillic: no majority, so the user is asked rather than told.
        let url = try file(["hello", "world", "wisdom", "привіт", "завжди", "їжак"])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DictionaryManager.survey(url: url)?.detected == nil)
    }

    @Test func theCyrillicPairIsDecidedOnExclusiveWordsNotTotals() throws {
        // A Russian list where most words could also be Ukrainian — the real one scores
        // 1.23:1, which no margin on totals can separate. The words only Russian can
        // spell are what settles it.
        let url = try file(["ток", "сон", "рот", "кот", "мышь", "ёж"])
        defer { try? FileManager.default.removeItem(at: url) }
        let survey = try #require(DictionaryManager.survey(url: url))
        #expect(survey.usable[.ukrainian] == 4)
        #expect(survey.usable[.russian] == 6)
        #expect(survey.exclusive[.russian] == 2)
        #expect(survey.exclusive[.ukrainian] == nil)
        #expect(survey.detected == .russian)
    }

    @Test func aFileWithBothCyrillicAlphabetsRefusesToGuess() throws {
        let url = try file(["мышь", "ёж", "їжак", "ґанок"])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DictionaryManager.survey(url: url)?.detected == nil)
    }

    @Test func sharedCyrillicAloneIsAmbiguous() throws {
        // Words spelled only from letters both alphabets have. Neither language can claim
        // them, and picking one at random would put them in the wrong dictionary.
        let url = try file(["ток", "сон", "рот", "кот"])
        let survey = try #require(DictionaryManager.survey(url: url))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(survey.usable[.ukrainian] == 4)
        #expect(survey.usable[.russian] == 4)
        #expect(survey.detected == nil)
    }

    @Test func itCountsWhatItCannotUse() throws {
        let url = try file(["hello", "wisdom", "hello/NGX", "1234 word", ""])
        defer { try? FileManager.default.removeItem(at: url) }
        let survey = try #require(DictionaryManager.survey(url: url))
        #expect(survey.usable[.english] == 2)
        #expect(survey.unusable == 2, "empty lines are dropped by the parser, not counted")
        #expect(survey.detected == .english)
    }

    @Test func anEmptyOrUnreadableFileSaysSo() throws {
        let empty = try file([])
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(DictionaryManager.survey(url: empty)?.detected == nil)
        #expect(DictionaryManager.survey(url: empty)?.totalUsable == 0)
        #expect(DictionaryManager.survey(url: URL(fileURLWithPath: "/nonexistent/x.txt")) == nil)
    }

    @Test func countsReportEveryLanguage() {
        let manager = DictionaryManager()
        let counts = manager.wordCounts()
        for language in Language.allCases {
            #expect(counts[language] ?? 0 > 90_000, "\(language.rawValue)")
        }
    }
}
