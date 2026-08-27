import Cocoa
import Foundation

// Log uncaught exceptions so the app doesn't silently die on first launch
NSSetUncaughtExceptionHandler { exception in
    print("[MacKeySwitch] UNCAUGHT EXCEPTION: \(exception.name.rawValue) - \(exception.reason ?? "no reason")")
    print("[MacKeySwitch] Stack trace: \(exception.callStackSymbols.joined(separator: "\n"))")
}

let app = NSApplication.shared

// Build-time mode: render the app icon into an .iconset directory and exit. Drawing the
// icon from the same code the About tab uses keeps the two from drifting, and keeps a
// binary blob out of the repository. Invoked by installer/build_installer.sh.
let arguments = ProcessInfo.processInfo.arguments
if let flagIndex = arguments.firstIndex(of: "--export-iconset") {
    guard flagIndex + 1 < arguments.count else {
        print("usage: \(arguments[0]) --export-iconset <output.iconset>")
        exit(2)
    }
    let output = URL(fileURLWithPath: arguments[flagIndex + 1])
    do {
        try AppIconRenderer.writeIconSet(to: output)
        print("[MacKeySwitch] Wrote iconset to \(output.path)")
        exit(0)
    } catch {
        print("[MacKeySwitch] Failed to write iconset: \(error.localizedDescription)")
        exit(1)
    }
}

// Support mode: report where the app found its resources, and exit.
if arguments.contains("--print-diagnostics") {
    print(Localization.shared.diagnosticsReport())
    print("\nCurrent layout: \(LayoutFlag.currentLayoutDisplayName)")
    print("Enabled input sources:")
    for source in InputSourceManager.enabledSourceSummaries() {
        let tag = source.languageTag ?? "(none)"
        let corrected = InputSourceManager.language(ofSourceID: source.id)?.rawValue
        let badge = corrected.map { "drawn flag (\($0))" }
            ?? AppDelegate.badge(forOtherLayout: source.languageTag)
        print("  \(source.id)  lang=\(tag)  badge=\(badge)")
    }
    // Dead keys break the one-keystroke-one-character rule the backspace count depends on,
    // so words containing them are left alone. Which keys they are is layout-specific
    // (US International's ' and `), and this is the way to see it without guessing.
    let profile = InputSourceManager.deadKeyProfile()
    if profile.dead.isEmpty {
        print("Dead keys on the current layout: none")
    } else {
        let labels = profile.dead.sorted().map { keycode -> String in
            let char = KeyMapping.unshifted[keycode].map { String($0.en) } ?? "?"
            let note = profile.resolvedByBoundary.contains(keycode)
                ? "corrected at the end of a word only"
                : "never corrected"
            return "0x\(String(keycode, radix: 16)) (\(char)) — \(note)"
        }
        print("Dead keys on the current layout:")
        for label in labels { print("  \(label)") }
    }
    print("Dictionaries: EN=\(DictionaryManager.shared.isEnglishWord("hello") ? "loaded" : "EMPTY")")
    exit(0)
}

// Install-time mode: turn the login item on or off and exit.
//
// Goes through SMAppService, the same path as the Settings toggle, so the installer and
// the app can never disagree about whether "start at login" is on. An installer that
// registered a login item by some other route (an AppleScript "login item", say) would
// leave the toggle in Settings reading false while the app really did launch at login.
if let flagIndex = arguments.firstIndex(where: {
    $0 == "--enable-login-item" || $0 == "--disable-login-item"
}) {
    let enable = arguments[flagIndex] == "--enable-login-item"
    do {
        try LoginItem.setEnabled(enable)
        print("[MacKeySwitch] Login item \(enable ? "enabled" : "disabled").")
        exit(0)
    } catch {
        print("[MacKeySwitch] Could not update login item: \(error.localizedDescription)")
        exit(1)
    }
}

// Single-instance guard: if another MacKeySwitch is already running, bail out gracefully.
// This prevents "two icons + one dies" behaviour when launched from both login item and Finder.
//
// Only applies to a real bundle. A bare `swift run` build has no bundle identifier of its
// own, and falling back to the shipped app's would make the development build refuse to
// start whenever the installed one happens to be running.
if let myBundleID = Bundle.main.bundleIdentifier {
    let myPID = ProcessInfo.processInfo.processIdentifier
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
        .filter { $0.processIdentifier != myPID }
    if let other = running.first {
        print("[MacKeySwitch] Another instance is already running (pid=\(other.processIdentifier)), exiting.")
        exit(0)
    }
}

let delegate = AppDelegate()
app.delegate = delegate

// Hide from Dock (menu bar only app)
app.setActivationPolicy(.accessory)

app.run()
