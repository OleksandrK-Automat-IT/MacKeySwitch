import Foundation

/// Text that must never be treated as a mistyped word, however convincing the layout
/// evidence looks.
///
/// The buffer collects letter keys, and on a US layout several of those keys are
/// punctuation — so a bare domain like "ok.ua" arrives looking exactly like an ordinary
/// word. Rewriting it as Cyrillic breaks a link the user is about to follow.
///
/// Borrowed from SwitchFix (github.com/rundax/SwitchFix, MIT), which skips URLs, emails and
/// identifier-shaped text before consulting its dictionaries.
enum WordFilter {

    /// Common top-level domains. Treating every two-letter suffix as a TLD is unsafe here:
    /// Ukrainian letters typed on a US layout use punctuation keys, and ordinary forms
    /// such as "мають" become `vf.nm`. A generic `[a-z]{2,}` rule silently discarded more
    /// than two percent of the frequency corpus before detection could inspect it.
    private static let commonTopLevelDomains: Set<String> = [
        "app", "biz", "ca", "co", "com", "de", "dev", "edu", "eu", "gov", "info",
        "io", "me", "net", "online", "org", "pl", "ru", "site", "store", "tech",
        "ua", "uk", "us",
    ]

    /// A bare hostname: at least two valid hostname characters, a dot, then a known TLD.
    ///
    /// Deliberately strict about what surrounds the dot. Ukrainian "ю" is the "." key, so
    /// "дякую" typed on a US layout is "lzre." — a looser rule would skip it and the word
    /// would never be corrected.
    static func shouldSkip(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let lower = text.lowercased()

        if lower.hasPrefix("http") || lower.hasPrefix("www.") || lower.hasPrefix("ftp") {
            return true
        }
        if text.contains("@") {
            return true
        }
        if looksLikeBareDomain(lower) {
            return true
        }
        if hasInternalCapital(text) {
            return true
        }
        return false
    }

    private static func looksLikeBareDomain(_ lowercased: String) -> Bool {
        let parts = lowercased.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count >= 2,
              commonTopLevelDomains.contains(String(parts[1])) else { return false }
        let hostname = parts[0]
        guard hostname.first != "-", hostname.last != "-" else { return false }
        return hostname.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }

    /// camelCase and similar identifier shapes: an uppercase letter after a lowercase one.
    /// A capitalised word ("Привіт" → "Ghbdsn") does not qualify, which is the point.
    private static func hasInternalCapital(_ text: String) -> Bool {
        var previousWasLowercase = false
        for character in text {
            if character.isUppercase && previousWasLowercase {
                return true
            }
            previousWasLowercase = character.isLowercase
        }
        return false
    }
}
