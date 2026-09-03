import AppKit
import Foundation

/// Word lookup backed by the macOS spelling dictionaries.
///
/// The bundled 50k word lists have holes wide enough to disable the whole feature. The
/// Ukrainian list contains no word beginning "при" at all, so "привіт", "приїхати" and
/// everything like them were unknown; "дякую", "добре", "треба" and "тобі" are missing
/// too. Since a correction needs a dictionary hit to reach the confidence threshold, those
/// words were simply never corrected. macOS ships a complete Ukrainian dictionary, it is
/// already installed, and a lookup costs ~0.13ms — far cheaper than being wrong.
///
/// The bundled lists stay as a first-pass cache and as a fallback when a language is not
/// installed on the machine.
///
/// NSSpellChecker is not thread-safe and belongs to AppKit's main thread. Detection runs on
/// the main thread for this reason; the hop below is defensive and should never fire.
final class SystemSpellChecker {
    static let shared = SystemSpellChecker()

    private let availableLanguages: Set<String>
    private var cache: [String: Bool] = [:]
    private let cacheLock = NSLock()

    /// Keeps the cache from growing without bound in a process that runs for weeks.
    private static let maxCacheEntries = 20_000

    private init() {
        // NSSpellChecker belongs to AppKit's main thread, and `shared`'s first touch
        // decides which thread constructs it — hop if that happens to be a background one.
        if Thread.isMainThread {
            availableLanguages = Set(NSSpellChecker.shared.availableLanguages)
        } else {
            availableLanguages = DispatchQueue.main.sync { Set(NSSpellChecker.shared.availableLanguages) }
        }
        let installed = Language.allCases.filter { languageCode(for: $0) != nil }
        print("[LayoutSwitcher] System dictionaries available: "
              + (installed.map(\.rawValue).joined(separator: ", ").isEmpty
                 ? "none" : installed.map(\.rawValue).joined(separator: ", ")))
    }

    /// The spell-checker language tag, or nil when that dictionary is not installed.
    private func languageCode(for language: Language) -> String? {
        let candidates: [String]
        switch language {
        case .english: candidates = ["en", "en_US", "en_GB"]
        case .ukrainian: candidates = ["uk", "uk_UA"]
        case .russian: candidates = ["ru", "ru_RU"]
        }
        return candidates.first { availableLanguages.contains($0) }
    }

    /// Whether this machine can check the given language at all.
    func supports(_ language: Language) -> Bool {
        languageCode(for: language) != nil
    }

    func isWord(_ word: String, language: Language) -> Bool {
        guard let code = languageCode(for: language) else { return false }

        // The checker ignores punctuation, so it accepts ",elm" as English on the strength
        // of "elm" — and the buffer does hold punctuation, because several US-layout
        // punctuation keys are Ukrainian letters. Without this guard, "будь" typed on a US
        // layout arrives as ",elm", counts as a real English word, and vetoes its own
        // correction.
        guard ProtoLanguage.usesScript(word, of: language) else { return false }

        let key = code + ":" + word
        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached = cached { return cached }

        let result = check(word, code: code)

        cacheLock.lock()
        if cache.count >= Self.maxCacheEntries { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        cacheLock.unlock()

        return result
    }

    private func check(_ word: String, code: String) -> Bool {
        guard !Thread.isMainThread else { return checkOnMain(word, code: code) }
        return DispatchQueue.main.sync { checkOnMain(word, code: code) }
    }

    private func checkOnMain(_ word: String, code: String) -> Bool {
        let misspelling = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: code,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return misspelling.location == NSNotFound
    }
}
