import Cocoa
import Foundation

final class DictionaryManager: WordSource {
    static let shared = DictionaryManager()

    private var englishWords: Set<String> = []
    private var ukrainianWords: Set<String> = []
    /// No bundled list ships for Russian; the system dictionary carries it. Imports land
    /// here so the lookup chain is the same shape for every language.
    private var russianWords: Set<String> = []

    // Prefix sets for fast partial-word lookup (first 3 chars of every word)
    private var englishPrefixes: Set<String> = []
    private var ukrainianPrefixes: Set<String> = []
    private var russianPrefixes: Set<String> = []

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
        // Works on UTF-8 bytes rather than Characters. Splitting a 4MB string into
        // Characters means grapheme breaking every byte; splitting bytes on '\n' is a
        // memchr. Trimming is ASCII-only on purpose — that is what a word list contains —
        // and the BOM is checked at the start rather than replaced across the whole file.
        var words: [String] = []
        content.utf8.withContiguousStorageIfAvailable { buffer in
            words = parse(buffer)
        } ?? {
            // A non-contiguous String (bridged NSString) is copied once, then parsed.
            var copy = content; copy.makeContiguousUTF8()
            copy.utf8.withContiguousStorageIfAvailable { words = parse($0) }
        }()
        return words
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        var words: [String] = []
        words.reserveCapacity(bytes.count / 8)
        var i = bytes.startIndex
        // UTF-8 BOM: EF BB BF.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        let end = bytes.endIndex
        while i < end {
            var lineEnd = i
            while lineEnd < end, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            var s = i, e = lineEnd
            while s < e, isSpace(bytes[s]) { s += 1 }
            while s < e, isSpace(bytes[e - 1]) { e -= 1 }
            if s < e, let line = String(bytes: UnsafeBufferPointer(rebasing: bytes[s..<e]), encoding: .utf8) {
                words.append(line.lowercased())
            }
            i = lineEnd + 1
        }
        return words
    }

    @inline(__always)
    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0B || b == 0x0C
    }

    /// Build the two sets for one word list. Pure: no lock, no shared state, so callers
    /// can run it before taking the lock and swap the result in atomically.
    private static func index(_ words: [String]) -> (words: Set<String>, prefixes: Set<String>) {
        var set = Set<String>(minimumCapacity: words.count)
        var prefixes = Set<String>()
        for word in words {
            set.insert(word)
            if word.count >= 3 { prefixes.insert(String(word.prefix(3))) }
        }
        return (set, prefixes)
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
        // Everything is parsed and indexed into locals first. The lock is taken only for
        // the swap, so readers see either the complete old dictionary or the complete new
        // one, and never wait on a parse. Holding the lock across the parse — as this used
        // to — stalled every lookup on the main thread for as long as the user's custom
        // files took to read, which for a 370k-word file is a quarter of a second.
        var en = Self.readBundled("en_words").map(Self.parseWordList) ?? []
        var ua = Self.readBundled("ua_words").map(Self.parseWordList) ?? []
        en += customEnglishWords.map { $0.lowercased() }
        ua += customUkrainianWords.map { $0.lowercased() }
        for path in englishPaths { en += Self.readFile(path).map(Self.parseWordList) ?? [] }
        for path in ukrainianPaths { ua += Self.readFile(path).map(Self.parseWordList) ?? [] }

        let enIndex = Self.index(en)
        let uaIndex = Self.index(ua)

        lock.lock()
        englishWords = enIndex.words
        englishPrefixes = enIndex.prefixes
        ukrainianWords = uaIndex.words
        ukrainianPrefixes = uaIndex.prefixes
        lock.unlock()

        print("[LayoutSwitcher] Dictionaries rebuilt: EN=\(enIndex.words.count), UA=\(uaIndex.words.count)")
    }

    private static func readBundled(_ name: String) -> String? {
        guard let url = ResourceBundle.url(forResource: name, extension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func readFile(_ path: String) -> String? {
        let content = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        if content == nil { print("[LayoutSwitcher] ERROR: Could not read dictionary file: \(path)") }
        return content
    }

    private func loadBundledDictionaries() {
        let start = CFAbsoluteTimeGetCurrent()

        var enSet: Set<String> = []
        var enPrefix: Set<String> = []
        var uaSet: Set<String> = []
        var uaPrefix: Set<String> = []

        if let enContent = findResource("en_words", ext: "txt")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            (enSet, enPrefix) = Self.index(Self.parseWordList(enContent))
        }
        if let uaContent = findResource("ua_words", ext: "txt")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            (uaSet, uaPrefix) = Self.index(Self.parseWordList(uaContent))
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
        case .russian: bundled = isRussianWord(word)
        }
        return bundled || SystemSpellChecker.shared.isWord(word, language: language)
    }

    func isPrefix(_ prefix: String, language: Language) -> Bool {
        switch language {
        case .english: return isEnglishPrefix(prefix)
        case .ukrainian: return isUkrainianPrefix(prefix)
        case .russian: return isRussianPrefix(prefix)
        }
    }

    func isRussianWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        lock.lock(); defer { lock.unlock() }
        return russianWords.contains(lower)
    }

    /// With no corpus there is no basis for calling a prefix invalid, so an empty index
    /// answers "could be" — the same answer the other languages give for a prefix too
    /// short to judge. Anything else would hand every Russian word a bonus it did not earn.
    func isRussianPrefix(_ prefix: String) -> Bool {
        let lower = prefix.lowercased()
        guard lower.count >= 3 else { return true }
        let p = String(lower.prefix(3))
        lock.lock(); defer { lock.unlock() }
        return russianPrefixes.isEmpty || russianPrefixes.contains(p)
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

    /// Parse and merge an imported file without blocking SwiftUI. The completion is always
    /// delivered on the main queue so callers can update settings safely.
    func loadDictionaryFileAsync(
        url: URL, language: Language, completion: @escaping (Int) -> Void
    ) {
        mutationQueue.async { [weak self] in
            let count = self?.loadDictionaryFileNow(url: url, language: language) ?? 0
            DispatchQueue.main.async { completion(count) }
        }
    }

    private func loadDictionaryFileNow(url: URL, language: Language) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("[LayoutSwitcher] ERROR: Could not read dictionary file: \(url.path)")
            return 0
        }

        // A Hunspell/TSV/frequency file is still plain text, but its complete rows are not
        // words and would never match typed input. Silently accepting them made the UI say
        // an import succeeded while adding nothing useful to detection.
        let words = Self.parseWordList(content).filter {
            Self.isValidImportedWord($0, language: language)
        }
        let index = Self.index(words)

        lock.lock()
        switch language {
        case .english:
            englishWords.formUnion(index.words)
            englishPrefixes.formUnion(index.prefixes)
        case .ukrainian:
            ukrainianWords.formUnion(index.words)
            ukrainianPrefixes.formUnion(index.prefixes)
        case .russian:
            russianWords.formUnion(index.words)
            russianPrefixes.formUnion(index.prefixes)
        }
        let enCount = englishWords.count
        let uaCount = ukrainianWords.count
        lock.unlock()

        print("[LayoutSwitcher] Loaded \(words.count) words from \(url.lastPathComponent) for \(language.rawValue). Total EN=\(enCount), UA=\(uaCount)")
        return index.words.count
    }

    static func isValidImportedWord(_ word: String, language: Language) -> Bool {
        guard !word.isEmpty else { return false }
        let apostrophes: Set<Character> = ["'", "’", "ʼ"]
        var hasLetter = false
        for character in word.lowercased() {
            if apostrophes.contains(character) { continue }
            switch language {
            case .english:
                guard character.isASCII && character.isLetter else { return false }
            case .ukrainian:
                guard "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя".contains(character) else {
                    return false
                }
            case .russian:
                guard "абвгдеёжзийклмнопрстуфхцчшщъыьэюя".contains(character) else {
                    return false
                }
            }
            hasLetter = true
        }
        return hasLetter
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
