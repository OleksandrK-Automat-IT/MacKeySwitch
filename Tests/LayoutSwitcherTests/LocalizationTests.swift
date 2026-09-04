import Testing
import Foundation
@testable import LayoutSwitcher

/// The translations are two hand-edited files that have to stay in step. Nothing in the
/// compiler notices when one of them loses a key — the UI just quietly falls back to
/// English, or prints a raw dotted key — so the check has to live here.
@Suite struct LocalizationTests {

    /// Read straight from Sources/, the way `Corpus` reads the word lists: these tests are
    /// about the shipped data, not about how the app happens to find it at runtime.
    static func table(_ code: String) -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LayoutSwitcherTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/LayoutSwitcher/Resources/\(code).lproj/Localizable.strings")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: String]
        else {
            return [:]
        }
        return plist
    }

    static let english = table("en")
    static let ukrainian = table("uk")

    @Test func bothTablesParse() {
        // A stray unescaped quote or a missing semicolon makes the whole file unreadable,
        // and the app would silently show every key untranslated.
        #expect(Self.english.count > 50)
        #expect(Self.ukrainian.count > 50)
    }

    @Test func ukrainianCoversEveryEnglishKey() {
        let missing = Set(Self.english.keys).subtracting(Self.ukrainian.keys).sorted()
        #expect(missing.isEmpty, "not translated: \(missing.joined(separator: ", "))")
    }

    @Test func ukrainianHasNoKeysEnglishLacks() {
        // The other direction matters too: a key only in the Ukrainian file is either a
        // typo or a string that will never render for an English user.
        let extra = Set(Self.ukrainian.keys).subtracting(Self.english.keys).sorted()
        #expect(extra.isEmpty, "not in the English table: \(extra.joined(separator: ", "))")
    }

    @Test func noTranslationIsEmpty() {
        for (key, value) in Self.ukrainian where value.trimmingCharacters(in: .whitespaces).isEmpty {
            Issue.record("'\(key)' is empty in the Ukrainian table")
        }
    }

    @Test func formatSpecifiersMatchAcrossTables() {
        // A translation with a different set of placeholders than its English original
        // feeds `String(format:)` arguments it does not expect — at best wrong text, at
        // worst a crash reading past the argument list.
        for (key, source) in Self.english {
            guard let translated = Self.ukrainian[key] else { continue }
            let expected = Self.specifiers(in: source)
            let actual = Self.specifiers(in: translated)
            #expect(expected == actual,
                    "'\(key)': English has \(expected), Ukrainian has \(actual)")
        }
    }

    @Test func multiArgumentStringsUsePositionalSpecifiers() {
        // With two or more arguments the order can legitimately differ between languages,
        // so those strings have to be positional ("%1$d") for translators to reorder them.
        for (key, source) in Self.english where Self.specifiers(in: source).count > 1 {
            #expect(source.contains("$"),
                    "'\(key)' takes several arguments but is not positional: \(source)")
        }
    }

    @Test func everyKeyUsedInTheAppExists() {
        // Guards the opposite drift: a key renamed in code but not in the tables would show
        // up as a raw "some.dotted.key" in the UI.
        let used = [
            "menu.enabled", "menu.undo", "menu.currentLayout", "menu.corrections",
            "menu.correctionsWithTotal", "menu.settings", "menu.quit", "window.settings",
            "language.english", "language.ukrainian", "language.other", "language.system",
            "tab.general", "tab.detection", "tab.perApp", "tab.dictionary",
            "tab.statistics", "tab.hotkeys", "tab.about", "language.russian",
            "general.pair", "pair.automatic", "menu.pair", "dictionary.importLanguage",
            "exceptions.search", "exceptions.noMatches", "exceptions.editHelp",
            "exceptions.clearConfirm", "stats.resetConfirm", "dictionary.cancel",
            "perApp.addPrompt", "perApp.addFromFinder",
            "dictionary.wordCount", "dictionary.detected", "dictionary.ambiguous",
            "dictionary.noneForLanguage", "dictionary.skipped", "dictionary.addFile",
            "hotkey.disabled", "hotkey.label", "hotkey.recording", "hotkey.hint",
            "sensitivity.low", "sensitivity.medium", "sensitivity.high", "sensitivity.veryHigh",
            "dictionary.importedCount", "stats.exceptions", "perApp.removeHelp",
            "about.version", "detection.minLength",
        ]
        for key in used {
            #expect(Self.english[key] != nil, "'\(key)' is used in code but missing from en.lproj")
        }
    }

    // MARK: - Helpers

    /// The format specifiers in a string, as a sorted multiset — "%1$d" and "%d" both
    /// reduce to "d", since what matters is the argument types, not their order.
    static func specifiers(in text: String) -> [String] {
        var found: [String] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else { index += 1; continue }
            var cursor = index + 1
            // Skip a positional prefix like "1$".
            var digits = ""
            while cursor < characters.count, characters[cursor].isNumber {
                digits.append(characters[cursor])
                cursor += 1
            }
            if cursor < characters.count, characters[cursor] == "$" {
                cursor += 1
            } else {
                cursor = index + 1 // the digits were not positional after all
            }
            guard cursor < characters.count else { break }
            let conversion = characters[cursor]
            if conversion == "%" {
                index = cursor + 1 // a literal "%%"
                continue
            }
            found.append(String(conversion))
            index = cursor + 1
        }
        return found.sorted()
    }
}
