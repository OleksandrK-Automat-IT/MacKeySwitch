import Cocoa
import Foundation

final class DictionaryManager {
    static let shared = DictionaryManager()

    private var englishWords: Set<String> = []
    private var ukrainianWords: Set<String> = []

    // Prefix sets for fast partial-word lookup (first 3 chars of every word)
    private var englishPrefixes: Set<String> = []
    private var ukrainianPrefixes: Set<String> = []

    private let spellChecker = NSSpellChecker.shared

    private init() {
        loadBundledDictionaries()
    }

    private func loadBundledDictionaries() {
        let start = CFAbsoluteTimeGetCurrent()

        if let enURL = findResource("en_words", ext: "txt"),
           let enContent = try? String(contentsOf: enURL, encoding: .utf8) {
            let words = enContent.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            englishWords = Set(words)
            englishPrefixes = Set(words.compactMap { word in
                word.count >= 3 ? String(word.prefix(3)) : nil
            })
        }

        if let uaURL = findResource("ua_words", ext: "txt"),
           let uaContent = try? String(contentsOf: uaURL, encoding: .utf8) {
            let words = uaContent.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            ukrainianWords = Set(words)
            ukrainianPrefixes = Set(words.compactMap { word in
                word.count >= 3 ? String(word.prefix(3)) : nil
            })
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("[LayoutSwitcher] Dictionaries loaded: EN=\(englishWords.count) words, UA=\(ukrainianWords.count) words (\(String(format: "%.1f", elapsed * 1000))ms)")
    }

    // MARK: - Public API

    /// Check if a word exists in the English dictionary
    func isEnglishWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        if englishWords.contains(lower) { return true }
        // Fallback: macOS spell checker
        let range = spellChecker.checkSpelling(of: lower, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    /// Check if a word exists in the Ukrainian dictionary
    func isUkrainianWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        if ukrainianWords.contains(lower) { return true }
        // Fallback: macOS spell checker
        let range = spellChecker.checkSpelling(of: lower, startingAt: 0, language: "uk", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    /// Check if a 3+ char prefix could start an English word
    func isEnglishPrefix(_ prefix: String) -> Bool {
        let lower = prefix.lowercased()
        if lower.count >= 3 {
            return englishPrefixes.contains(String(lower.prefix(3)))
        }
        return true // too short to tell
    }

    /// Check if a 3+ char prefix could start a Ukrainian word
    func isUkrainianPrefix(_ prefix: String) -> Bool {
        let lower = prefix.lowercased()
        if lower.count >= 3 {
            return ukrainianPrefixes.contains(String(lower.prefix(3)))
        }
        return true
    }

    // MARK: - Resource Loading

    /// Find a resource file, checking multiple locations
    private func findResource(_ name: String, ext: String) -> URL? {
        // 1. SPM Bundle.module (works when running from swift build)
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        // 2. Main app bundle Resources/ (works in .app bundle)
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        // 3. Next to the executable
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let siblingURL = execURL.deletingLastPathComponent().appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: siblingURL.path) {
            return siblingURL
        }
        // 4. In ../Resources/ relative to executable (standard .app layout)
        let resourcesURL = execURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: resourcesURL.path) {
            return resourcesURL
        }
        print("[LayoutSwitcher] WARNING: Could not find resource \(name).\(ext)")
        return nil
    }

    // MARK: - Custom Dictionary File Loading

    /// Load a dictionary file from disk, adding all words to the specified language set and rebuilding prefix index.
    /// Returns the number of words loaded.
    @discardableResult
    func loadDictionaryFile(url: URL, language: Language) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("[LayoutSwitcher] ERROR: Could not read dictionary file: \(url.path)")
            return 0
        }

        let words = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        switch language {
        case .english:
            for word in words {
                englishWords.insert(word)
                if word.count >= 3 {
                    englishPrefixes.insert(String(word.prefix(3)))
                }
            }
        case .ukrainian:
            for word in words {
                ukrainianWords.insert(word)
                if word.count >= 3 {
                    ukrainianPrefixes.insert(String(word.prefix(3)))
                }
            }
        }

        print("[LayoutSwitcher] Loaded \(words.count) words from \(url.lastPathComponent) for \(language.rawValue). Total EN=\(englishWords.count), UA=\(ukrainianWords.count)")
        return words.count
    }

    /// Reload all custom dictionary files from saved paths
    func reloadCustomDictionaryFiles(englishPaths: [String], ukrainianPaths: [String]) {
        for path in englishPaths {
            let url = URL(fileURLWithPath: path)
            loadDictionaryFile(url: url, language: .english)
        }
        for path in ukrainianPaths {
            let url = URL(fileURLWithPath: path)
            loadDictionaryFile(url: url, language: .ukrainian)
        }
    }

    /// Add custom words
    func addCustomEnglishWords(_ words: [String]) {
        for word in words {
            let lower = word.lowercased()
            englishWords.insert(lower)
            if lower.count >= 3 {
                englishPrefixes.insert(String(lower.prefix(3)))
            }
        }
    }

    func addCustomUkrainianWords(_ words: [String]) {
        for word in words {
            let lower = word.lowercased()
            ukrainianWords.insert(lower)
            if lower.count >= 3 {
                ukrainianPrefixes.insert(String(lower.prefix(3)))
            }
        }
    }
}
