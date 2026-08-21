import Foundation

/// Flags for keyboard layouts the app does not itself correct.
///
/// Ukrainian and English are drawn by hand, to match the app icon. Every other layout gets
/// its flag as an emoji: a hand-drawn set for several dozen languages would be a great deal
/// of `NSBezierPath` for something the user sees only in passing, and the system already
/// renders these correctly at menu-bar size.
///
/// The mapping is language → country, which is a lossy relation and always will be: a
/// language can be spoken in many countries, and picking one flag for it is a convention,
/// not a fact. The choices below follow the layout names macOS itself uses.
enum LayoutFlag {

    /// Tags that name their own region, resolved before the primary-subtag table below.
    /// Without these, "pt-BR" would fall back to Portugal and "zh-Hant" to mainland China.
    private static let regionSpecific: [String: String] = [
        "pt-br": "BR", "pt-pt": "PT",
        "en-gb": "GB", "en-us": "US", "en-au": "AU", "en-ca": "CA", "en-nz": "NZ",
        "en-ie": "IE", "en-za": "ZA", "en-in": "IN",
        "zh-hans": "CN", "zh-hant": "TW", "zh-cn": "CN", "zh-tw": "TW", "zh-hk": "HK",
        "es-mx": "MX", "es-ar": "AR", "es-419": "MX",
        "fr-ca": "CA", "fr-ch": "CH", "fr-be": "BE",
        "de-at": "AT", "de-ch": "CH",
        "nl-be": "BE",
    ]

    /// Primary language subtag → country. The major world languages, as asked for; a layout
    /// outside this set falls back to its language code as text, which still says more than
    /// the "??" this replaces.
    private static let byLanguage: [String: String] = [
        // Europe — west
        "en": "GB", "de": "DE", "fr": "FR", "es": "ES", "it": "IT", "pt": "PT",
        "nl": "NL", "ga": "IE", "cy": "GB", "ca": "ES", "eu": "ES", "gl": "ES",
        // Europe — north
        "sv": "SE", "da": "DK", "fi": "FI", "is": "IS",
        "no": "NO", "nb": "NO", "nn": "NO",
        // Europe — central and east
        "pl": "PL", "cs": "CZ", "sk": "SK", "hu": "HU", "ro": "RO", "bg": "BG",
        "uk": "UA", "ru": "RU", "be": "BY", "el": "GR",
        "lt": "LT", "lv": "LV", "et": "EE",
        "sl": "SI", "hr": "HR", "sr": "RS", "bs": "BA", "mk": "MK", "sq": "AL",
        // Caucasus and Central Asia
        "tr": "TR", "az": "AZ", "hy": "AM", "ka": "GE",
        "kk": "KZ", "uz": "UZ", "ky": "KG", "tg": "TJ", "tk": "TM", "mn": "MN",
        // Middle East
        "he": "IL", "ar": "SA", "fa": "IR", "ku": "IQ",
        // South Asia
        "hi": "IN", "bn": "BD", "pa": "IN", "gu": "IN", "ta": "IN", "te": "IN",
        "kn": "IN", "ml": "IN", "mr": "IN", "or": "IN", "as": "IN",
        "ur": "PK", "ne": "NP", "si": "LK", "dv": "MV",
        // East and Southeast Asia
        "zh": "CN", "ja": "JP", "ko": "KR",
        "th": "TH", "vi": "VN", "id": "ID", "ms": "MY", "tl": "PH", "fil": "PH",
        "km": "KH", "lo": "LA", "my": "MM",
        // Africa
        "af": "ZA", "zu": "ZA", "xh": "ZA", "sw": "KE", "am": "ET", "ha": "NG",
        "yo": "NG", "ig": "NG", "so": "SO", "mg": "MG",
    ]

    /// The country whose flag stands for this language tag, or nil if it is not covered.
    static func regionCode(forLanguageTag tag: String) -> String? {
        let normalized = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        if let region = regionSpecific[normalized] {
            return region
        }
        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return byLanguage[primary]
    }

    /// The flag emoji for a language tag, or nil if the language is not covered.
    static func emoji(forLanguageTag tag: String) -> String? {
        regionCode(forLanguageTag: tag).flatMap(emoji(forRegionCode:))
    }

    /// Build a flag from a two-letter country code, as the pair of regional indicator
    /// symbols that the system composes into one glyph.
    static func emoji(forRegionCode region: String) -> String? {
        let letters = Array(region.uppercased().unicodeScalars)
        guard letters.count == 2 else { return nil }
        var flag = ""
        for letter in letters {
            guard ("A"..."Z").contains(letter),
                  let indicator = Unicode.Scalar(letter.value + 0x1F1E6 - 0x41) else {
                return nil
            }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    /// Short text for a layout with no flag: the language code, uppercased. Not pretty, but
    /// it names the layout, which "??" never did.
    static func fallbackLabel(forLanguageTag tag: String) -> String {
        let primary = tag.split(separator: "-").first.map(String.init) ?? tag
        return primary.uppercased()
    }
}

// MARK: - Naming the current layout

extension LayoutFlag {
    /// The language's own name, in the app's interface language: "Polish" or "Польська".
    static func displayName(forLanguageTag tag: String) -> String? {
        let primary = tag.split(separator: "-").first.map(String.init) ?? tag
        let locale = Locale(identifier: Localization.shared.language.localizationCode)
        return locale.localizedString(forLanguageCode: primary)
    }

    /// How to name the active layout wherever the app spells it out — the menu's
    /// "Current: …" line and the Status section in Settings.
    ///
    /// Both used to print a flat "Other" for anything outside the corrected pair, which is
    /// the same non-answer the "??" badge gave.
    static var currentLayoutDisplayName: String {
        if let language = InputSourceManager.currentLanguage() {
            return language.localizedName
        }
        if let tag = InputSourceManager.currentSourceLanguageTag(),
           let name = displayName(forLanguageTag: tag) {
            return name.localizedCapitalized
        }
        return L("language.other")
    }
}
