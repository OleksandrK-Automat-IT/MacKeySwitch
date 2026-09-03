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
    ]

    /// The two ЙЦУКЕН Russian layouts Apple ships. Russian-Phonetic is a QWERTY-shaped
    /// layout with different geometry and is deliberately absent.
    static let russianSourceIDs: Set<String> = [
        "com.apple.keylayout.Russian",
        "com.apple.keylayout.RussianWin",
    ]

    /// Latin layouts this app treats as "English". Matched exactly: a substring test for
    /// "US" also matches unrelated third-party layouts with "US" anywhere in their ID.
    static let englishSourceIDs: Set<String> = [
        "com.apple.keylayout.US",
        "com.apple.keylayout.USInternational-PC",
        "com.apple.keylayout.USExtended",
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.British",
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

    /// Which Cyrillic layout the user was last seen in. English pairs with this one: a
    /// word typed in English that reads as Cyrillic is retyped in the layout the user
    /// actually works in, not in whichever Cyrillic layout happens to be listed first.
    ///
    /// Persisted, because the app is relaunched far more often than the user changes
    /// languages — every rebuild, every login — and each relaunch used to forget the pair
    /// and fall back to the first Cyrillic layout in the system's list.
    private static let lastUsedCyrillicKey = "lastUsedCyrillicLanguage"
    private static var lastUsedCyrillic: Language? = UserDefaults.standard
        .string(forKey: lastUsedCyrillicKey).flatMap(Language.init(rawValue:)) {
        didSet {
            guard lastUsedCyrillic != oldValue else { return }
            UserDefaults.standard.set(lastUsedCyrillic?.rawValue, forKey: lastUsedCyrillicKey)
        }
    }

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
        // Match exactly. A name containing "Ukrainian" does not mean it has the same
        // physical key geometry as Ukrainian-PC; treating it as supported can make the
        // counted-backspace correction retype the wrong characters.
        if ukrainianSourceIDs.contains(sourceID) {
            return .ukrainian
        }
        if russianSourceIDs.contains(sourceID) {
            return .russian
        }
        return nil
    }

    /// The language of the current input source, as a BCP-47 tag ("pl", "de", "zh-Hans").
    ///
    /// Asked of TIS rather than parsed out of the source ID: the ID is a bundle-style name
    /// that only sometimes contains the language ("com.apple.keylayout.Polish" does,
    /// "com.apple.keylayout.ABC" does not), and third-party layouts follow no convention at
    /// all. Every input source declares its languages.
    static func currentSourceLanguageTag() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue()
                  as? [String]
        else {
            return nil
        }
        return languages.first
    }

    /// The current language if it is one this app handles, nil otherwise.
    static func currentLanguage() -> Language? {
        let sourceID = currentInputSourceID()
        guard let language = language(ofSourceID: sourceID) else { return nil }
        lastUsedSourceID[language] = sourceID
        if language.isCyrillic { lastUsedCyrillic = language }
        return language
    }

    /// The Cyrillic layout English corrections switch to: the one the user last worked
    /// in, or failing that the first enabled one. Nil when none is enabled — then there is
    /// nothing for an English word to be corrected into, and the engine leaves it alone.
    static func preferredCyrillicLanguage() -> Language? {
        let enabled = enabledSources().compactMap { language(ofSourceID: $0.id) }
        if let last = lastUsedCyrillic, enabled.contains(last) { return last }
        return enabled.first { $0.isCyrillic }
    }

    /// The exact source whose geometry will be used for a language switch. Correction
    /// planning needs this before the switch because two Ukrainian layouts map И/І to
    /// different physical keys.
    static func preferredSourceID(for language: Language) -> String? {
        let current = currentInputSourceID()
        if self.language(ofSourceID: current) == language {
            lastUsedSourceID[language] = current
            if language.isCyrillic { lastUsedCyrillic = language }
            return current
        }
        let enabled = enabledSources()
        if let remembered = lastUsedSourceID[language],
           enabled.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return enabled.first(where: { self.language(ofSourceID: $0.id) == language })?.id
    }

    /// Switch to the specified language input source, preferring the exact source the user
    /// was last using for it.
    static func switchTo(_ language: Language) {
        let enabled = enabledSources()
        if language.isCyrillic { lastUsedCyrillic = language }

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

    /// What the current layout's dead keys do to the reconstruction buffer.
    ///
    /// `KeyMapping` is a static table, so it claims every buffered key produces exactly one
    /// character — the assumption the backspace count rests on. Whether that holds is a
    /// property of the *layout*, not of the keycode: on US International `'` and `` ` ``
    /// are dead keys that print nothing and wait to combine with whatever comes next.
    struct DeadKeyProfile {
        /// Keys that put no character on screen when pressed.
        var dead: Set<UInt16> = []

        /// The subset a following space resolves into exactly the one character
        /// `KeyMapping` predicts. A word ending in one of these is still reconstructable —
        /// only the trailing space is missing, because the space was spent resolving it.
        var resolvedByBoundary: Set<UInt16> = []
    }

    /// Probe the current layout for dead keys.
    ///
    /// Asked of the layout rather than hardcoded: which keys are dead differs per layout,
    /// and third-party layouts follow no convention at all.
    static func deadKeyProfile() -> DeadKeyProfile {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            // Input methods (as opposed to keyboard layouts) expose no layout data. They
            // do not reconstruct reliably anyway; report nothing rather than guess.
            return DeadKeyProfile()
        }
        return deadKeyProfile(layoutData: unsafeBitCast(dataPtr, to: CFData.self) as Data)
    }

    /// The probe itself, against a layout given explicitly — the seam the tests use to
    /// check a layout other than whichever one the tester happens to be running.
    static func deadKeyProfile(layoutData: Data) -> DeadKeyProfile {
        var profile = DeadKeyProfile()
        for keycode in KeyMapping.bufferedKeycodes {
            var state: UInt32 = 0
            // Deliberately *without* kUCKeyTranslateNoDeadKeysBit: the point is to observe
            // the dead-key behaviour, not to suppress it.
            let pressed = translate(keycode, layoutData: layoutData, deadKeyState: &state)
            // A key that emits no character, or more than one, breaks the one-keystroke-
            // one-character invariant either way.
            guard let pressed, pressed.count != 1 else { continue }
            profile.dead.insert(keycode)

            // Does the boundary space resolve it into the character the static map claims?
            // On US International `'` then space types `'` — the word survives intact and
            // only the space is gone. A dead key that resolves into something else, or
            // into several characters, cannot be reconstructed at all.
            guard pressed.isEmpty,
                  let expected = KeyMapping.unshifted[keycode].map({ String($0.en) }),
                  let resolved = translate(spaceKeycode, layoutData: layoutData, deadKeyState: &state),
                  resolved == expected else {
                continue
            }
            profile.resolvedByBoundary.insert(keycode)
        }
        return profile
    }

    private static let spaceKeycode: UInt16 = 0x31

    /// One keystroke through the layout, carrying the dead-key state forward the way the
    /// text system does. Returns the characters it puts on screen — empty for a dead key.
    static func translate(
        _ keycode: UInt16,
        layoutData: Data,
        deadKeyState: inout UInt32,
        modifierState: UInt32 = 0
    ) -> String? {
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        var state = deadKeyState
        let status = layoutData.withUnsafeBytes { pointer -> OSStatus in
            guard let base = pointer.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keycode, UInt16(kUCKeyActionDown), modifierState, UInt32(LMGetKbdType()),
                0, &state, characters.count, &length, &characters
            )
        }
        guard status == noErr else { return nil }
        deadKeyState = state
        return String(utf16CodeUnits: characters, count: max(0, length))
    }

    /// Every enabled source with the language it declares — what `--print-diagnostics`
    /// prints, so "my layout shows as XX" can be answered without guessing.
    static func enabledSourceSummaries() -> [(id: String, languageTag: String?)] {
        enabledSources().map { entry in
            var tag: String?
            if let ptr = TISGetInputSourceProperty(entry.source, kTISPropertyInputSourceLanguages),
               let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue()
                   as? [String] {
                tag = languages.first
            }
            return (entry.id, tag)
        }
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
