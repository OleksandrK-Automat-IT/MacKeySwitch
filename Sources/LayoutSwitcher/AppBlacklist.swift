import Foundation

/// Applications where an automatic correction is more likely to damage something than to
/// help: terminals and editors, where the text is code and a wrong-layout word is usually
/// deliberate.
///
/// The default list is from SwitchFix (github.com/rundax/SwitchFix, MIT).
enum AppBlacklist {
    static let defaults: Set<String> = [
        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        // Editors and IDEs
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "org.vim.MacVim",
        "com.apple.dt.Xcode",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.CLion",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.goland",
        "com.jetbrains.rider",
        "com.jetbrains.rubymine",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.fleet",
    ]

    /// Whether corrections are disabled for an app.
    ///
    /// An explicit user rule wins in either direction, so a default-blacklisted app can be
    /// re-enabled. Only the user's decisions are stored — never the resolved set — so that
    /// additions to `defaults` in a later release reach people who already have settings
    /// saved. That storage shape is the useful half of the idea, borrowed from SwitchFix.
    static func isExcluded(bundleID: String, userRules: [SettingsModel.AppRule]) -> Bool {
        if let rule = userRules.first(where: { $0.bundleID == bundleID }) {
            return rule.isExcluded
        }
        return defaults.contains(bundleID)
    }
}
