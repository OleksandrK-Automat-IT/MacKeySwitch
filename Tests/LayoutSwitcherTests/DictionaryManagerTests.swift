import Testing
import Foundation
@testable import LayoutSwitcher

/// Word-list parsing and the atomic rebuild. Each test uses its own DictionaryManager, so
/// nothing here touches the shared instance or the user's real custom files.
@Suite struct DictionaryManagerTests {
    @Test func rebuildUsesTheSameValidationAsImport() throws {
        let url = try tempFile("qwzxvb\nпривіт\nhello 42\nслово/AB\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let dm = DictionaryManager()
        #expect(dm.loadDictionaryFile(url: url, language: .english) == 1)
        dm.rebuildAsync(customEnglishWords: [], customUkrainianWords: [],
                        englishPaths: [url.path], ukrainianPaths: [url.path],
                        russianPaths: [url.path])
        dm.addCustomEnglishWords([])
        #expect(dm.isEnglishWord("qwzxvb"))
        #expect(!dm.isEnglishWord("привіт"))
        #expect(!dm.isEnglishWord("hello 42"))
        #expect(!dm.isUkrainianWord("qwzxvb"))
        #expect(!dm.isRussianWord("привіт"))
        #expect(!dm.isUkrainianWord("слово/ab"))
    }

    @Test func importedRowsMustBeWordsInTheSelectedLanguage() {
        #expect(DictionaryManager.isValidImportedWord("hello", language: .english))
        #expect(DictionaryManager.isValidImportedWord("can't", language: .english))
        #expect(!DictionaryManager.isValidImportedWord("hello 42", language: .english))
        #expect(!DictionaryManager.isValidImportedWord("привіт", language: .english))
        #expect(DictionaryManager.isValidImportedWord("привіт", language: .ukrainian))
        #expect(DictionaryManager.isValidImportedWord("імʼя", language: .ukrainian))
        #expect(!DictionaryManager.isValidImportedWord("слово 100", language: .ukrainian))
        #expect(!DictionaryManager.isValidImportedWord("слово/AB", language: .ukrainian))
    }

    private func tempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mks-\(UUID().uuidString).txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // Words the system spell checker will not rescue, so a miss is a real miss.
    private let nonsense = ["qwzxvb", "plmkjq", "xzcvqw"]

    @Test func stripsAWindowsByteOrderMark() throws {
        let url = try tempFile("\u{FEFF}qwzxvb\nplmkjq\n")
        let dm = DictionaryManager()
        #expect(dm.loadDictionaryFile(url: url, language: .english) == 2)
        #expect(dm.isEnglishWord("qwzxvb"), "the first word carried the BOM and never matched")
        #expect(dm.isEnglishWord("plmkjq"))
    }

    @Test func handlesWindowsLineEndingsAndBlankLines() throws {
        let url = try tempFile("qwzxvb\r\n\r\n   \r\nplmkjq\r\n")
        let dm = DictionaryManager()
        #expect(dm.loadDictionaryFile(url: url, language: .english) == 2)
        #expect(dm.isEnglishWord("qwzxvb"))
        #expect(dm.isEnglishWord("plmkjq"))
    }

    @Test func trimsAndLowercases() throws {
        let url = try tempFile("  ПрИвІт  \n\tСЛОВО\t\n")
        let dm = DictionaryManager()
        #expect(dm.loadDictionaryFile(url: url, language: .ukrainian) == 2)
        #expect(dm.isUkrainianWord("привіт"))
        #expect(dm.isUkrainianWord("СЛОВО"), "lookup is case-insensitive too")
    }

    @Test func aMissingFileLoadsNothingAndDoesNotCrash() {
        let dm = DictionaryManager()
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).txt")
        #expect(dm.loadDictionaryFile(url: missing, language: .english) == 0)
    }

    @Test func prefixIndexFollowsTheWords() throws {
        let url = try tempFile("qwzxvb\n")
        let dm = DictionaryManager()
        _ = dm.loadDictionaryFile(url: url, language: .english)
        #expect(dm.isEnglishPrefix("qwz"))
        #expect(dm.isEnglishPrefix("qwzABC"), "only the first three letters matter")
        #expect(!dm.isEnglishPrefix("zzz"))
        #expect(dm.isEnglishPrefix("qw"), "too short to judge — must not veto")
    }

    @Test func customWordsSurviveARebuild() throws {
        let dm = DictionaryManager()
        dm.addCustomEnglishWords(["qwzxvb"])
        dm.addCustomUkrainianWords(["plmkjq"])
        #expect(dm.isEnglishWord("qwzxvb"))

        // Rebuild with the same customisations: the words must still be there afterwards,
        // and the rebuild must have finished before we look (it is async).
        dm.rebuildAsync(customEnglishWords: ["qwzxvb"], customUkrainianWords: ["plmkjq"],
                        englishPaths: [], ukrainianPaths: [])
        // A sync mutation queues behind the rebuild, so returning from it proves the
        // rebuild has completed.
        dm.addCustomEnglishWords([])
        #expect(dm.isEnglishWord("qwzxvb"))
        #expect(dm.isUkrainianWord("plmkjq"))
    }

    @Test func aRebuildRemovesAWordThatIsNoLongerCustom() {
        let dm = DictionaryManager()
        dm.addCustomEnglishWords(["qwzxvb"])
        #expect(dm.isEnglishWord("qwzxvb"))
        dm.rebuildAsync(customEnglishWords: [], customUkrainianWords: [],
                        englishPaths: [], ukrainianPaths: [])
        dm.addCustomEnglishWords([])   // barrier
        #expect(!dm.isEnglishWord("qwzxvb"), "removal is the whole point of a rebuild")
    }

    @Test func aRebuildLoadsCustomFiles() throws {
        let url = try tempFile("xzcvqw\n")
        let dm = DictionaryManager()
        dm.rebuildAsync(customEnglishWords: [], customUkrainianWords: [],
                        englishPaths: [url.path], ukrainianPaths: [])
        dm.addCustomEnglishWords([])   // barrier
        #expect(dm.isEnglishWord("xzcvqw"))
    }

    @Test func parsingALargeFileIsFastEnoughToNotMatterOffMain() throws {
        // 370k words was 233ms with the old parser. This is a regression guard, not a
        // benchmark: generous bound, deterministic input.
        var lines: [String] = []
        lines.reserveCapacity(200_000)
        for i in 0..<200_000 {
            var value = i
            var bytes = [UInt8](repeating: Character("a").asciiValue!, count: 5)
            bytes[0] = Character("w").asciiValue!
            for position in stride(from: 4, through: 1, by: -1) {
                bytes[position] += UInt8(value % 26)
                value /= 26
            }
            lines.append(String(bytes: bytes, encoding: .utf8)!)
        }
        let url = try tempFile(lines.joined(separator: "\n"))
        let dm = DictionaryManager()
        let t = CFAbsoluteTimeGetCurrent()
        let count = dm.loadDictionaryFile(url: url, language: .english)
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
        print(String(format: "BENCH parse 200k words: %.0f ms", ms))
        #expect(count == 200_000)
        #expect(ms < 1_000)
    }
}
