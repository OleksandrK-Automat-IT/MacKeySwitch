import Cocoa
import Foundation

final class DictionaryManager: WordSource {
    static let shared = DictionaryManager()

    private var englishWords: Set<String> = []
    private var ukrainianWords: Set<String> = []

    // Prefix sets for fast partial-word lookup (first 3 chars of every word)
    private var englishPrefixes: Set<String> = []
    private var ukrainianPrefixes: Set<String> = []

    // Guards all four sets. Reads happen on the correction queue (bg thread);
    // writes happen on the main thread (SettingsView import, launch init).
    // Without the lock, Set mutation racing with membership check crashes.
    private let lock = NSLock()

    private init() {
        loadBundledDictionaries()
    }

    private func loadBundledDictionaries() {
        let start = CFAbsoluteTimeGetCurrent()

        var enSet: Set<String> = []
        var enPrefix: Set<String> = []
        var uaSet: Set<String> = []
        var uaPrefix: Set<String> = []

        if let enURL = findResource("en_words", ext: "txt"),
           let enContent = try? String(contentsOf: enURL, encoding: .utf8) {
            let words = enContent.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            enSet = Set(words)
            enPrefix = Set(words.compactMap { word in
                word.count >= 3 ? String(word.prefix(3)) : nil
            })
        }

        if let uaURL = findResource("ua_words", ext: "txt"),
           let uaContent = try? String(contentsOf: uaURL, encoding: .utf8) {
            let words = uaContent.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
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

    /// Safely get the SPM resource bundle without crashing
    private static let safeResourceBundle: Bundle? = {
        let bundleName = "LayoutSwitcher_LayoutSwitcher.bundle"

        // 1. SPM default: next to the executable
        let mainPath = Bundle.main.bundleURL.appendingPathComponent(bundleName).path
        if let b = Bundle(path: mainPath) { return b }

        // 2. Inside Contents/Resources/ (.app bundle layout)
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let appResourcesPath = execURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent(bundleName).path
        if let b = Bundle(path: appResourcesPath) { return b }

        // 3. Next to the executable directly
        let siblingPath = execURL.deletingLastPathComponent()
            .appendingPathComponent(bundleName).path
        if let b = Bundle(path: siblingPath) { return b }

        return nil
    }()

    /// Find a resource file, checking multiple locations
    private func findResource(_ name: String, ext: String) -> URL? {
        // 1. Safe resource bundle (SPM bundle, avoids fatalError)
        if let bundle = DictionaryManager.safeResourceBundle,
           let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        // 2. Main app bundle Resources/ (loose files)
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
