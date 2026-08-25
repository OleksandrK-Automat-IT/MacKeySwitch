import Cocoa
import Foundation

final class DictionaryManager: WordSource {
    static let shared = DictionaryManager()

    private var englishWords: Set<String> = []
    private var ukrainianWords: Set<String> = []

    // Prefix sets for fast partial-word lookup (first 3 chars of every word)
    private var englishPrefixes: Set<String> = []
    private var ukrainianPrefixes: Set<String> = []

    // Guards all four sets. Recursive because a full rebuild holds the lock across all of
    // its phases and then reuses the same small mutation helpers. Readers therefore see
    // either the old complete dictionary or the new complete dictionary, never a half-built
    // mix of bundled and custom words.
    private let lock = NSRecursiveLock()

    /// Orders every dictionary mutation. A rebuild is intentionally asynchronous because
    /// parsing the bundled corpora should not hitch SwiftUI, while imports/additions use
    /// `sync` so they cannot overtake an already queued rebuild and then be erased by it.
    private let mutationQueue = DispatchQueue(
        label: "com.layoutswitcher.dictionary-mutations",
        qos: .userInitiated
    )

    /// Internal for isolated tests; production uses `shared`.
    init() {
        loadBundledDictionaries()
    }

    /// One line of a word-list file → one lowercase word. Strips the UTF-8 BOM that
    /// Windows editors prepend — `.whitespaces` does not cover U+FEFF, so the first word
    /// of an imported file used to be stored as "\u{FEFF}word" and never matched.
    private static func parseWordList(_ content: String) -> [String] {
        content.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Rebuild everything from the bundled lists plus the given customizations. The only
    /// way to *remove* a custom word or an imported file mid-session — the sets merge
    /// bundled and custom words, so removal means rebuilding from scratch.
    func rebuildAsync(
        customEnglishWords: [String],
        customUkrainianWords: [String],
        englishPaths: [String],
        ukrainianPaths: [String]
    ) {
        mutationQueue.async { [weak self] in
            self?.rebuildNow(
                customEnglishWords: customEnglishWords,
                customUkrainianWords: customUkrainianWords,
                englishPaths: englishPaths,
                ukrainianPaths: ukrainianPaths
            )
        }
    }

    private func rebuildNow(
        customEnglishWords: [String],
        customUkrainianWords: [String],
        englishPaths: [String],
        ukrainianPaths: [String]
    ) {
        // Keep the published sets atomic across the complete rebuild. NSRecursiveLock lets
        // the helpers below take the same lock without deadlocking.
        lock.lock(); defer { lock.unlock() }
        loadBundledDictionaries()
        addCustomEnglishWordsNow(customEnglishWords)
        addCustomUkrainianWordsNow(customUkrainianWords)
        reloadCustomDictionaryFilesNow(
            englishPaths: englishPaths,
            ukrainianPaths: ukrainianPaths
        )
    }

    private func loadBundledDictionaries() {
        let start = CFAbsoluteTimeGetCurrent()

        var enSet: Set<String> = []
        var enPrefix: Set<String> = []
        var uaSet: Set<String> = []
        var uaPrefix: Set<String> = []

        if let enURL = findResource("en_words", ext: "txt"),
           let enContent = try? String(contentsOf: enURL, encoding: .utf8) {
            let words = Self.parseWordList(enContent)
            enSet = Set(words)
            enPrefix = Set(words.compactMap { word in
                word.count >= 3 ? String(word.prefix(3)) : nil
            })
        }

        if let uaURL = findResource("ua_words", ext: "txt"),
           let uaContent = try? String(contentsOf: uaURL, encoding: .utf8) {
            let words = Self.parseWordList(uaContent)
            uaSet = Set(words)
            uaPrefix = Set(words.compactMap { word in
                word.count >= 3 ? String(word.prefix(3)) : nil
            })
        }

        lock.lock()
        englishWords = enSet
        englishPrefixes = enPrefix
        ukrainianWords = uaSet
        ukrainianPrefixes = uaPrefix
        let enCount = englishWords.count
        let uaCount = ukrainianWords.count
        lock.unlock()

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("[LayoutSwitcher] Dictionaries loaded: EN=\(enCount) words, UA=\(uaCount) words (\(String(format: "%.1f", elapsed * 1000))ms)")
    }

    // MARK: - WordSource

    /// The bundled list first — a plain set lookup, and it holds the user's custom words —
    /// then the system dictionary, which is what actually provides usable coverage.
    ///
    /// The bundled Ukrainian list is missing most everyday vocabulary: it contains no word
    /// beginning "при" at all, nor "дякую", "добре", "треба", "тобі". Since a correction
    /// cannot reach the confidence threshold without a dictionary hit, those words were
    /// never corrected — the feature looked broken while the detector was working exactly
    /// as designed on the data it had.
    func isWord(_ word: String, language: Language) -> Bool {
        let bundled: Bool
        switch language {
        case .english: bundled = isEnglishWord(word)
        case .ukrainian: bundled = isUkrainianWord(word)
        }
        return bundled || SystemSpellChecker.shared.isWord(word, language: language)
    }

    func isPrefix(_ prefix: String, language: Language) -> Bool {
        switch language {
        case .english: return isEnglishPrefix(prefix)
        case .ukrainian: return isUkrainianPrefix(prefix)
        }
    }

    // MARK: - Public API

    /// Check if a word exists in the bundled English list. Prefer `isWord(_:language:)`,
    /// which also consults the system dictionary.
    func isEnglishWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        lock.lock(); defer { lock.unlock() }
        return englishWords.contains(lower)
    }

    /// Check if a word exists in the Ukrainian dictionary
    func isUkrainianWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        lock.lock(); defer { lock.unlock() }
        return ukrainianWords.contains(lower)
    }

    /// Check if a 3+ char prefix could start an English word
    func isEnglishPrefix(_ prefix: String) -> Bool {
        let lower = prefix.lowercased()
        guard lower.count >= 3 else { return true } // too short to tell
        let p = String(lower.prefix(3))
        lock.lock(); defer { lock.unlock() }
        return englishPrefixes.contains(p)
    }

    /// Check if a 3+ char prefix could start a Ukrainian word
    func isUkrainianPrefix(_ prefix: String) -> Bool {
        let lower = prefix.lowercased()
        guard lower.count >= 3 else { return true }
        let p = String(lower.prefix(3))
        lock.lock(); defer { lock.unlock() }
        return ukrainianPrefixes.contains(p)
    }

    // MARK: - Resource Loading

    /// Find a resource file, checking every layout the installer has used. See
    /// `ResourceBundle`, which the localization tables share.
    private func findResource(_ name: String, ext: String) -> URL? {
        guard let url = ResourceBundle.url(forResource: name, extension: ext) else {
            print("[LayoutSwitcher] WARNING: Could not find resource \(name).\(ext)")
            return nil
        }
        return url
    }

    // MARK: - Custom Dictionary File Loading

    /// Load a dictionary file from disk, adding all words to the specified language set and rebuilding prefix index.
    /// Returns the number of words loaded.
    @discardableResult
    func loadDictionaryFile(url: URL, language: Language) -> Int {
        mutationQueue.sync {
            loadDictionaryFileNow(url: url, language: language)
        }
    }

    private func loadDictionaryFileNow(url: URL, language: Language) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("[LayoutSwitcher] ERROR: Could not read dictionary file: \(url.path)")
            return 0
        }

        let words = Self.parseWordList(content)

        lock.lock()
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
        let enCount = englishWords.count
        let uaCount = ukrainianWords.count
        lock.unlock()

        print("[LayoutSwitcher] Loaded \(words.count) words from \(url.lastPathComponent) for \(language.rawValue). Total EN=\(enCount), UA=\(uaCount)")
        return words.count
    }

    /// Reload all custom dictionary files from saved paths
    func reloadCustomDictionaryFiles(englishPaths: [String], ukrainianPaths: [String]) {
        mutationQueue.sync {
            reloadCustomDictionaryFilesNow(
                englishPaths: englishPaths,
                ukrainianPaths: ukrainianPaths
            )
        }
    }

    private func reloadCustomDictionaryFilesNow(
        englishPaths: [String],
        ukrainianPaths: [String]
    ) {
        for path in englishPaths {
            let url = URL(fileURLWithPath: path)
            _ = loadDictionaryFileNow(url: url, language: .english)
        }
        for path in ukrainianPaths {
            let url = URL(fileURLWithPath: path)
            _ = loadDictionaryFileNow(url: url, language: .ukrainian)
        }
    }

    /// Add custom words
    func addCustomEnglishWords(_ words: [String]) {
        mutationQueue.sync {
            addCustomEnglishWordsNow(words)
        }
    }

    private func addCustomEnglishWordsNow(_ words: [String]) {
        lock.lock(); defer { lock.unlock() }
        for word in words {
            let lower = word.lowercased()
            englishWords.insert(lower)
            if lower.count >= 3 {
                englishPrefixes.insert(String(lower.prefix(3)))
            }
        }
    }

    func addCustomUkrainianWords(_ words: [String]) {
        mutationQueue.sync {
            addCustomUkrainianWordsNow(words)
        }
    }

    private func addCustomUkrainianWordsNow(_ words: [String]) {
        lock.lock(); defer { lock.unlock() }
        for word in words {
            let lower = word.lowercased()
            ukrainianWords.insert(lower)
            if lower.count >= 3 {
                ukrainianPrefixes.insert(String(lower.prefix(3)))
            }
        }
    }
}
