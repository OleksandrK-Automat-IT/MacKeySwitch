import Testing
import Foundation
@testable import LayoutSwitcher

/// The menu bar used to show "??" for every layout that is not English or Ukrainian —
/// which told the user only that it was neither, when what they wanted to know was which
/// layout had actually taken over.
@Suite struct LayoutFlagTests {

    @Test(arguments: [
        ("pl", "\u{1F1F5}\u{1F1F1}"),   // Poland
        ("de", "\u{1F1E9}\u{1F1EA}"),   // Germany
        ("fr", "\u{1F1EB}\u{1F1F7}"),   // France
        ("ja", "\u{1F1EF}\u{1F1F5}"),   // Japan
        ("uk", "\u{1F1FA}\u{1F1E6}"),   // Ukraine
    ])
    func majorLanguagesGetTheirFlag(tag: String, expected: String) {
        #expect(LayoutFlag.emoji(forLanguageTag: tag) == expected)
    }

    @Test func aFlagIsTwoRegionalIndicators() {
        // The emoji is built, not written out: two regional indicator symbols the system
        // composes into one glyph. "PL" must land on U+1F1F5 U+1F1F1.
        let flag = LayoutFlag.emoji(forRegionCode: "PL")
        #expect(flag?.unicodeScalars.map(\.value) == [0x1F1F5, 0x1F1F1])
        #expect(flag?.count == 1, "a flag is one grapheme cluster")
    }

    @Test func regionSpecificTagsBeatTheLanguageDefault() {
        // Brazilian Portuguese must not show Portugal's flag, nor Traditional Chinese
        // mainland China's.
        #expect(LayoutFlag.regionCode(forLanguageTag: "pt-BR") == "BR")
        #expect(LayoutFlag.regionCode(forLanguageTag: "pt") == "PT")
        #expect(LayoutFlag.regionCode(forLanguageTag: "zh-Hant") == "TW")
        #expect(LayoutFlag.regionCode(forLanguageTag: "zh-Hans") == "CN")
        #expect(LayoutFlag.regionCode(forLanguageTag: "en-US") == "US")
        #expect(LayoutFlag.regionCode(forLanguageTag: "fr-CA") == "CA")
    }

    @Test func tagsAreMatchedCaseAndSeparatorInsensitively() {
        // TIS is not consistent about either; "zh_Hant" and "PT-br" both turn up.
        #expect(LayoutFlag.regionCode(forLanguageTag: "PT-br") == "BR")
        #expect(LayoutFlag.regionCode(forLanguageTag: "zh_Hant") == "TW")
        #expect(LayoutFlag.regionCode(forLanguageTag: "DE") == "DE")
    }

    @Test func aRegionalTagFallsBackToItsLanguage() {
        // "de-LI" (Liechtenstein) is not listed; it should still show Germany rather than
        // dropping to text.
        #expect(LayoutFlag.regionCode(forLanguageTag: "de-LI") == "DE")
        #expect(LayoutFlag.regionCode(forLanguageTag: "es-CO") == "ES")
    }

    @Test func everyMappedRegionProducesAValidFlag() {
        // Guards a typo in the table: a three-letter or lowercase code would silently
        // produce no flag at all, and the layout would show as text.
        for tag in ["pl", "de", "fr", "es", "it", "pt", "nl", "sv", "da", "fi", "no",
                    "cs", "sk", "hu", "ro", "bg", "el", "tr", "ru", "be", "he", "ar",
                    "fa", "hi", "th", "vi", "id", "zh", "ja", "ko", "lt", "lv", "et"] {
            let flag = LayoutFlag.emoji(forLanguageTag: tag)
            #expect(flag != nil, "'\(tag)' has no flag")
            #expect(flag?.count == 1, "'\(tag)' did not compose into one glyph")
        }
    }

    @Test func anUnknownLanguageFallsBackToItsCode() {
        // Better than "??": it names the layout even when the table does not cover it.
        #expect(LayoutFlag.emoji(forLanguageTag: "xyz") == nil)
        #expect(LayoutFlag.fallbackLabel(forLanguageTag: "xyz") == "XYZ")
        #expect(LayoutFlag.fallbackLabel(forLanguageTag: "xyz-Latn") == "XYZ")
    }

    @Test func aBadRegionCodeYieldsNoFlag() {
        #expect(LayoutFlag.emoji(forRegionCode: "P") == nil)
        #expect(LayoutFlag.emoji(forRegionCode: "POL") == nil)
        #expect(LayoutFlag.emoji(forRegionCode: "P1") == nil)
        #expect(LayoutFlag.emoji(forRegionCode: "") == nil)
    }

    // MARK: - The badge the menu bar actually shows

    @Test func theBadgeIsAFlagForAKnownLayout() {
        #expect(AppDelegate.badge(forOtherLayout: "pl") == "\u{1F1F5}\u{1F1F1}")
    }

    @Test func theBadgeFallsBackToTextRatherThanQuestionMarks() {
        #expect(AppDelegate.badge(forOtherLayout: "xyz") == "XYZ")
    }

    @Test func aLayoutDeclaringNoLanguageStillGetsSomething() {
        // Only reached when the input source reports no languages at all.
        #expect(AppDelegate.badge(forOtherLayout: nil) == "?")
        #expect(AppDelegate.badge(forOtherLayout: "") == "?")
    }

    @Test func theCorrectedPairIsCoveredToo() {
        // English and Ukrainian are drawn by hand for the menu bar, but their tags must
        // still resolve — the About tab and any future use depend on the same table.
        #expect(LayoutFlag.regionCode(forLanguageTag: "en") == "GB")
        #expect(LayoutFlag.regionCode(forLanguageTag: "uk") == "UA")
    }

    @Test func languagesAreNamedInTheInterfaceLanguage() {
        // Falls back to the key when no localization table is loaded, as in tests, so this
        // asserts the lookup works rather than a particular wording.
        let name = LayoutFlag.displayName(forLanguageTag: "pl")
        #expect(name != nil)
        #expect(name?.isEmpty == false)
    }
}

/// The badge is drawn into an image, so it also has to answer to the menu bar's theme.
@Suite struct LayoutBadgeImageTests {

    @Test func aFlagBadgeKeepsItsOwnColours() {
        let image = AppDelegate.badgeImage("\u{1F1F5}\u{1F1F1}")
        #expect(image != nil)
        #expect(image?.isTemplate == false, "a template flag would render as a silhouette")
    }

    @Test func aTextBadgeIsATemplateSoItSurvivesDarkMode() {
        // Drawn in black. Left non-template, it is invisible against a dark menu bar.
        let image = AppDelegate.badgeImage("XYZ")
        #expect(image != nil)
        #expect(image?.isTemplate == true)
    }

    @Test func everyBadgeIsTheSameSizeAsTheDrawnFlags() {
        // The status item must not change width when the layout changes.
        for badge in ["\u{1F1F5}\u{1F1F1}", "\u{1F1EF}\u{1F1F5}", "XYZ", "?"] {
            #expect(AppDelegate.badgeImage(badge)?.size == NSSize(width: 22, height: 14))
        }
    }

    @Test func anEmptyBadgeProducesNoImage() {
        #expect(AppDelegate.badgeImage("") == nil)
    }

    @Test func flagDetectionIsAboutRegionalIndicators() {
        #expect(AppDelegate.isFlagEmoji("\u{1F1FA}\u{1F1E6}"))
        #expect(!AppDelegate.isFlagEmoji("XYZ"))
        #expect(!AppDelegate.isFlagEmoji("?"))
        #expect(!AppDelegate.isFlagEmoji(""))
    }
}
