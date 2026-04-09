import Carbon
import Foundation

final class InputSourceManager {
    // Input source identifiers
    static let englishSourceID = "com.apple.keylayout.US"
    // Common Ukrainian input source IDs
    static let ukrainianSourceIDs: Set<String> = [
        "com.apple.keylayout.Ukrainian",
        "com.apple.keylayout.Ukrainian-PC",
        "com.apple.keylayout.UkrainianEnhanced",
    ]

    /// Returns the current input source identifier string
    static func currentInputSourceID() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return ""
        }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }

    /// Returns the current language if it's English or Ukrainian, nil otherwise
    static func currentLanguage() -> Language? {
        let sourceID = currentInputSourceID()
        if sourceID.contains("US") || sourceID.contains("ABC") || sourceID.contains("British") {
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

    /// Switch to the specified language input source
    static func switchTo(_ language: Language) {
        let targetID: String
        switch language {
        case .english:
            targetID = englishSourceID
        case .ukrainian:
            // Try to find the actual installed Ukrainian source
            targetID = findInstalledUkrainianSource() ?? "com.apple.keylayout.Ukrainian"
        }

        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return
        }

        for source in sources {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                continue
            }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            if id == targetID {
                TISSelectInputSource(source)
                return
            }
        }

        // Fallback: try partial match
        for source in sources {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                continue
            }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            switch language {
            case .english:
                if id.contains("US") || id.contains("ABC") {
                    TISSelectInputSource(source)
                    return
                }
            case .ukrainian:
                if id.lowercased().contains("ukrainian") {
                    TISSelectInputSource(source)
                    return
                }
            }
        }
    }

    /// Find the installed Ukrainian input source ID
    private static func findInstalledUkrainianSource() -> String? {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        for source in sources {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                continue
            }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            if id.lowercased().contains("ukrainian") {
                return id
            }
        }
        return nil
    }
}
