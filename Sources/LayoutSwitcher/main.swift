import Cocoa
import Foundation

// Log uncaught exceptions so the app doesn't silently die on first launch
NSSetUncaughtExceptionHandler { exception in
    print("[MacKeySwitch] UNCAUGHT EXCEPTION: \(exception.name.rawValue) - \(exception.reason ?? "no reason")")
    print("[MacKeySwitch] Stack trace: \(exception.callStackSymbols.joined(separator: "\n"))")
}

// Single-instance guard: if another MacKeySwitch is already running, bail out gracefully.
// This prevents "two icons + one dies" behaviour when launched from both login item and Finder.
let myBundleID = Bundle.main.bundleIdentifier ?? "com.okuzmin.mackeyswitch"
let myPID = ProcessInfo.processInfo.processIdentifier
let running = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
    .filter { $0.processIdentifier != myPID }
if !running.isEmpty {
    print("[MacKeySwitch] Another instance is already running (pid=\(running.first!.processIdentifier)), exiting.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Hide from Dock (menu bar only app)
app.setActivationPolicy(.accessory)

app.run()
