import Testing
@testable import LayoutSwitcher

/// Only the user's own decisions are persisted, never the resolved set, so that defaults
/// added in a later release reach people who already have settings saved.
@Suite struct AppBlacklistTests {

    private func rule(_ bundleID: String, excluded: Bool) -> SettingsModel.AppRule {
        SettingsModel.AppRule(bundleID: bundleID, name: bundleID, isExcluded: excluded)
    }

    @Test func terminalsAndEditorsAreExcludedByDefault() {
        #expect(AppBlacklist.isExcluded(bundleID: "com.apple.Terminal", userRules: []))
        #expect(AppBlacklist.isExcluded(bundleID: "com.microsoft.VSCode", userRules: []))
        #expect(AppBlacklist.isExcluded(bundleID: "com.jetbrains.intellij", userRules: []))
    }

    @Test func ordinaryAppsAreNotExcluded() {
        #expect(!AppBlacklist.isExcluded(bundleID: "com.apple.Safari", userRules: []))
        #expect(!AppBlacklist.isExcluded(bundleID: "com.tinyspeck.slackmacgap", userRules: []))
    }

    @Test func aUserRuleReEnablesADefaultBlacklistedApp() {
        let rules = [rule("com.apple.Terminal", excluded: false)]
        #expect(!AppBlacklist.isExcluded(bundleID: "com.apple.Terminal", userRules: rules))
    }

    @Test func aUserRuleExcludesAnAppThatIsNotADefault() {
        let rules = [rule("com.apple.Safari", excluded: true)]
        #expect(AppBlacklist.isExcluded(bundleID: "com.apple.Safari", userRules: rules))
    }

    @Test func rulesForOtherAppsDoNotLeak() {
        let rules = [rule("com.apple.Safari", excluded: true)]
        #expect(!AppBlacklist.isExcluded(bundleID: "com.apple.Notes", userRules: rules))
        #expect(AppBlacklist.isExcluded(bundleID: "com.apple.Terminal", userRules: rules))
    }
}
