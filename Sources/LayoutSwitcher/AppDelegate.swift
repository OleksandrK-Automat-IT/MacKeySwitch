import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = KeyboardMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check accessibility permissions
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            print("Accessibility permission not granted yet. Please grant it and restart the app.")
        }

        setupStatusBar()
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "UA⇄EN"
        }

        let menu = NSMenu()

        let enableItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enableItem.state = .on
        menu.addItem(enableItem)

        menu.addItem(NSMenuItem.separator())

        let currentLayout = NSMenuItem(
            title: "Current: \(InputSourceManager.currentLanguage()?.rawValue ?? "other")",
            action: nil,
            keyEquivalent: ""
        )
        currentLayout.isEnabled = false
        menu.addItem(currentLayout)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit LayoutSwitcher",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        monitor.isEnabled.toggle()
        sender.state = monitor.isEnabled ? .on : .off

        if let button = statusItem.button {
            button.title = monitor.isEnabled ? "UA⇄EN" : "UA⇄EN ⏸"
        }
    }

    @objc private func quitApp() {
        monitor.stop()
        NSApplication.shared.terminate(nil)
    }
}
