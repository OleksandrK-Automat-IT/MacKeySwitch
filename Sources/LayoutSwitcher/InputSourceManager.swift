import Carbon
import Foundation

/// Reads and selects keyboard input sources.
///
/// Main-thread only: the TIS APIs belong to the main thread, and the "last used source"
/// memory below is plain mutable state with no lock.
final class InputSourceManager {
    /// Common Ukrainian input source IDs
    static let ukrainianSourceIDs: Set<String> = [
        "com.apple.keylayout.Ukrainian",
        "com.apple.keylayout.Ukrainian-PC",
        "com.apple.keylayout.UkrainianEnhanced",
    ]

    /// Latin layouts this app treats as "English". Matched exactly: a substring test for
    /// "US" also matches unrelated third-party layouts with "US" anywhere in their ID.
    static let englishSourceIDs: Set<String> = [
        "com.apple.keylayout.US",
        "com.apple.keylayout.USInternational-PC",
        "com.apple.keylayout.USExtended",
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.ABC-QWERTZ",
        "com.apple.keylayout.ABC-AZERTY",
        "com.apple.keylayout.British",
        "com.apple.keylayout.British-PC",
        "com.apple.keylayout.Australian",
        "com.apple.keylayout.Canadian",
        "com.apple.keylayout.Irish",
    ]

    /// The source the user was last seen using for each language.
    ///
    /// Switching used to hardcode `com.apple.keylayout.US`, so a user who works on ABC or
    /// British — both recognised as English above — was silently moved onto a different
    /// layout by every correction. Remembering what they actually had selected keeps the
    /// switch reversible.
    private static var lastUsedSourceID: [Language: String] = [:]

    /// Returns the current input source identifier string
    static func currentInputSourceID() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return ""
        }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }

    /// Which language an input source ID belongs to, or nil if it is neither.
    static func language(ofSourceID sourceID: String) -> Language? {
        if englishSourceIDs.contains(sourceID) {
            return .english
        }
        // Check all known Ukrainian variants
        if ukrainianSourceIDs.contains(sourceID)
            || sourceID.lowercased().contains("ukrainian")
        {
            return .ukrainian
        }
        return nil
    }

    /// Returns the current language if it's English or Ukrainian, nil otherwise
    static func currentLanguage() -> Language? {
        let sourceID = currentInputSourceID()
        guard let language = language(ofSourceID: sourceID) else { return nil }
        lastUsedSourceID[language] = sourceID
        return language
    }

    /// Switch to the specified language input source, preferring the exact source the user
    /// was last using for it.
    static func switchTo(_ language: Language) {
        let enabled = enabledSources()

        // 1. The source this user actually works in, if it is still enabled.
        if let remembered = lastUsedSourceID[language],
           let source = enabled.first(where: { $0.id == remembered }) {
            TISSelectInputSource(source.source)
            return
        }

        // 2. Otherwise the first enabled source of that language, in the order the system
        //    lists them — never a hardcoded ID that may not even be the user's.
        if let source = enabled.first(where: { self.language(ofSourceID: $0.id) == language }) {
            lastUsedSourceID[language] = source.id
            TISSelectInputSource(source.source)
            return
        }

        print("[LayoutSwitcher] No enabled input source found for \(language.rawValue)")
    }

    /// Enabled (not merely installed) keyboard input sources, with their IDs.
    private static func enabledSources() -> [(source: TISInputSource, id: String)] {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue()
                as? [TISInputSource] else {
            return []
        }
        return sources.compactMap { source in
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                return nil
            }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            return (source, id)
        }
    }
}
