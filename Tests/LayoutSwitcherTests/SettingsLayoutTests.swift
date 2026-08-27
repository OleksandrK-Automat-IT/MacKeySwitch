import Testing
import AppKit
@testable import LayoutSwitcher

/// The settings window is a fixed size and its tab bar is not scrollable, so a translation
/// longer than the window is wide does not wrap or scroll — the titles would truncate.
///
/// Nothing about that fails at build time, and it only shows up in whichever language the
/// developer is not using. So the strings are measured here instead.
@Suite struct SettingsLayoutTests {

    /// Tab titles, in the order `SettingsView` declares them.
    static let tabKeys = [
        "tab.general", "tab.detection", "tab.perApp",
        "tab.dictionary", "tab.statistics", "tab.about",
    ]

    /// Width one tab needs beyond its text: 12pt horizontal padding on each side.
    ///
    /// An approximation of AppKit's own metrics — deliberately generous, since the cost of
    /// over-estimating is a slightly roomy window and the cost of under-estimating is the
    /// clipped tab bar this suite exists to prevent.
    static let perTabOverhead: CGFloat = 24

    static func tabBarWidth(titles: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let segments = titles.reduce(CGFloat.zero) { total, title in
            total + (title as NSString).size(withAttributes: attributes).width + perTabOverhead
        }
        return segments + CGFloat(max(0, titles.count - 1)) // one-point separators
    }

    @Test(arguments: ["en", "uk"])
    func tabTitlesFitTheWindow(code: String) {
        let table = LocalizationTests.table(code)
        let titles = Self.tabKeys.compactMap { table[$0] }
        #expect(titles.count == Self.tabKeys.count, "missing tab titles in \(code).lproj")

        let needed = Self.tabBarWidth(titles: titles)
        let available = SettingsView.contentSize.width
        let detail = "\(code) tab bar needs \(Int(needed))pt but the window offers "
            + "\(Int(available))pt: " + titles.joined(separator: " / ")
        #expect(needed <= available, "\(detail)")
    }

    @Test func theWindowIsSizedFromTheContentPlusItsPadding() {
        // AppDelegate sets the window's content size from `preferredSize`. If that drifted
        // from the frame the view actually asks for, the tab bar would be clipped by the
        // window rather than by its own frame — the same symptom, a different cause.
        #expect(SettingsView.preferredSize.width
                == SettingsView.contentSize.width + SettingsView.windowPadding * 2)
        #expect(SettingsView.preferredSize.height
                == SettingsView.contentSize.height + SettingsView.windowPadding * 2)
    }

    @Test func selectedTabFillsTheControlHeight() {
        // The original system tab style inset the blue selection from the grey control.
        #expect(SettingsView.selectedTabInset == 0)
        #expect(SettingsView.tabBarHeight > 0)
    }

    @Test func noTabTitleIsLongEnoughToCrowdTheBar() {
        // A single very long title squeezes every other tab, so cap them individually as
        // well as in total. Roughly the width of "Per-App Rules".
        let limit: CGFloat = 130
        for code in ["en", "uk"] {
            let table = LocalizationTests.table(code)
            for key in Self.tabKeys {
                guard let title = table[key] else { continue }
                let width = Self.tabBarWidth(titles: [title]) - Self.perTabOverhead
                #expect(width <= limit,
                        "\(code) '\(key)' = \"\(title)\" is \(Int(width))pt wide, over \(Int(limit))pt")
            }
        }
    }
}
