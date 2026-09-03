import Testing
import Foundation
@testable import LayoutSwitcher

/// The optional word lists shipped in `dictionaries/`. They are not compiled into the app —
/// they are imported by hand from Settings — so nothing else would notice if one were
/// replaced by a file of the wrong language, or by markup.
@Suite struct BundledOptionalDictionariesTests {

    /// The repository's own folder, found from this source file rather than a bundle: these
    /// files are repository content, not app resources.
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LayoutSwitcherTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("dictionaries")

    static let expected: [(file: String, language: Language, atLeast: Int)] = [
        ("english-words-alpha.txt", .english, 350_000),
        ("ukrainian-words-v10.txt", .ukrainian, 250_000),
        ("russian-words-ru-spelling-1.0.8.txt", .russian, 140_000),
    ]

    @Test(arguments: expected)
    func eachListIsTheLanguageItClaims(_ entry: (file: String, language: Language, atLeast: Int)) throws {
        let url = Self.folder.appendingPathComponent(entry.file)
        try #require(FileManager.default.fileExists(atPath: url.path), "missing \(entry.file)")

        let survey = try #require(DictionaryManager.survey(url: url))
        #expect(survey.detected == entry.language, "\(entry.file) reads as \(String(describing: survey.detected))")
        #expect(survey.usable[entry.language, default: 0] >= entry.atLeast, "\(entry.file)")
        // Some hyphenated forms are dropped — the buffer never produces one as a single
        // word, since a hyphen ends it. Anything beyond a rounding error means the file is
        // in the wrong format: markup, frequencies or Hunspell flags rather than words.
        let dropped = Double(survey.unusable) / Double(survey.totalUsable)
        #expect(dropped < 0.01, "\(entry.file) drops \(survey.unusable) lines")
    }
}
