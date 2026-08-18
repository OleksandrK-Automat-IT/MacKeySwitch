import Testing
@testable import LayoutSwitcher

/// The "Add Running App" popup used to be a button that added *every* running app at once,
/// so excluding a single app meant adding a dozen and deleting the rest. These cover the
/// list-building behind the popup that replaced it.
@Suite struct PerAppRulesTests {

    private func app(_ bundleID: String, _ name: String) -> PerAppTab.RunningApp {
        PerAppTab.RunningApp(bundleID: bundleID, name: name, icon: nil)
    }

    private func rule(_ bundleID: String) -> SettingsModel.AppRule {
        SettingsModel.AppRule(bundleID: bundleID, name: bundleID, isExcluded: true)
    }

    @Test func entriesAreSortedByDisplayName() {
        let sorted = PerAppTab.normalize([
            app("com.example.zed", "Zed"),
            app("com.example.arc", "Arc"),
            app("com.example.mail", "Mail"),
        ])
        #expect(sorted.map(\.name) == ["Arc", "Mail", "Zed"])
    }

    @Test func sortingIgnoresCase() {
        // A plain `<` on String would put every capitalised name before every lowercase one,
        // so "iTerm" would sort after "Xcode".
        let sorted = PerAppTab.normalize([
            app("com.example.xcode", "Xcode"),
            app("com.example.iterm", "iTerm"),
            app("com.example.arc", "Arc"),
        ])
        #expect(sorted.map(\.name) == ["Arc", "iTerm", "Xcode"])
    }

    @Test func duplicateBundleIDsCollapseToOne() {
        // An app running in several instances appears once per instance in
        // NSWorkspace.runningApplications. A repeated Identifiable id breaks ForEach.
        let unique = PerAppTab.normalize([
            app("com.example.term", "Terminal"),
            app("com.example.term", "Terminal"),
            app("com.example.term", "Terminal"),
        ])
        #expect(unique.count == 1)
        #expect(unique.first?.bundleID == "com.example.term")
    }

    @Test func deduplicationKeepsTheFirstEntry() {
        let unique = PerAppTab.normalize([
            app("com.example.term", "Terminal"),
            app("com.example.term", "Terminal (2)"),
        ])
        #expect(unique.map(\.name) == ["Terminal"])
    }

    @Test func appsAlreadyInTheListAreNotOffered() {
        let running = [app("com.example.arc", "Arc"), app("com.example.mail", "Mail")]
        let offered = PerAppTab.addable(from: running, existing: [rule("com.example.arc")])
        #expect(offered.map(\.bundleID) == ["com.example.mail"])
    }

    @Test func everythingIsOfferedWhenNothingIsListedYet() {
        let running = [app("com.example.arc", "Arc"), app("com.example.mail", "Mail")]
        #expect(PerAppTab.addable(from: running, existing: []).count == 2)
    }

    @Test func nothingIsOfferedOnceEveryRunningAppIsListed() {
        // This is what disables the popup, so it has to be exactly empty rather than merely
        // short — a stray entry would leave an enabled menu with no usable items.
        let running = [app("com.example.arc", "Arc"), app("com.example.mail", "Mail")]
        let existing = [rule("com.example.arc"), rule("com.example.mail")]
        #expect(PerAppTab.addable(from: running, existing: existing).isEmpty)
    }

    @Test func aRemovedAppBecomesAvailableAgain() {
        // The point of removing one app at a time: it goes straight back into the popup, so
        // an accidental removal costs one click rather than a trip to the Finder picker.
        let running = [app("com.example.arc", "Arc"), app("com.example.mail", "Mail")]
        var existing = [rule("com.example.arc"), rule("com.example.mail")]
        #expect(PerAppTab.addable(from: running, existing: existing).isEmpty)

        existing.removeAll { $0.bundleID == "com.example.arc" }
        #expect(PerAppTab.addable(from: running, existing: existing).map(\.bundleID)
                == ["com.example.arc"])
    }

    @Test func removingOneRuleLeavesTheOthersAlone() {
        // Rows are addressed by bundle ID, not by a captured index. An index captured when
        // the row was built goes stale as soon as an earlier row is removed, and the next
        // toggle or delete would land on the wrong app.
        var rules = [rule("com.example.arc"), rule("com.example.mail"), rule("com.example.zed")]
        rules.removeAll { $0.bundleID == "com.example.arc" }
        #expect(rules.map(\.bundleID) == ["com.example.mail", "com.example.zed"])
    }

    @Test func aRuleIsMatchedByBundleIDNotByName() {
        // The rule's display name comes from whichever source added it — the running app or
        // the Finder picker — and the two do not always agree ("Safari" vs "Safari.app").
        let running = [app("com.apple.Safari", "Safari")]
        let existing = [SettingsModel.AppRule(bundleID: "com.apple.Safari",
                                              name: "Something Else",
                                              isExcluded: false)]
        #expect(PerAppTab.addable(from: running, existing: existing).isEmpty)
    }
}
