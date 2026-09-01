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

    /// A bare hostname: at least two characters, a dot, then a TLD-like tail.
    ///
    /// Deliberately strict about what surrounds the dot. Ukrainian "ю" is the "." key, so
    /// "дякую" typed on a US layout is "lzre." — a looser rule would skip it and the word
    /// would never be corrected.
    private static let bareDomain = try! NSRegularExpression(
        pattern: "^[a-z0-9-]{2,}\\.[a-z]{2,}$",
        options: [.caseInsensitive]
    )

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
        let range = NSRange(lowercased.startIndex..<lowercased.endIndex, in: lowercased)
        return bareDomain.firstMatch(in: lowercased, options: [], range: range) != nil
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
