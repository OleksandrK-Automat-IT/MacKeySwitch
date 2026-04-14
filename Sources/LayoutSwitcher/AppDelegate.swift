import Cocoa
import Carbon
import Combine
import SwiftUI
import UserNotifications
import ObjCExceptionGuard

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = KeyboardMonitor()
    private var settingsWindow: NSWindow?
    private let settings = SettingsModel.shared
    private var accessibilityTimer: Timer?
    private var layoutObserverTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set runtime app icon (Dock/About/Alerts) to match the About-tab logo.
        NSApp.applicationIconImage = AppIconRenderer.makeAppIcon(size: 512)

        setupStatusBar()
        monitor.settings = settings
        monitor.onUndoRequest = { [weak self] in self?.handleUndoHotkey() }
        setupGlobalUndoHotkey()
        requestNotificationAuthorization()
        tryStartMonitor()
        startLayoutObserver()
    }

    /// Request notification permissions on launch. If the process's bundle is not registered
    /// with the system (ad-hoc signed), UNUserNotificationCenter APIs throw
    /// `NSInternalInconsistencyException`. We catch that via an ObjC try, and disable
    /// notifications at runtime so the app never crashes on a later correction.
    private func requestNotificationAuthorization() {
        // Guard the entire UN interaction behind ObjC exception handling — on ad-hoc-signed
        // bundles these APIs can throw `NSInternalInconsistencyException` (not a Swift error),
        // which would otherwise terminate the process.
        let ok = ObjCExceptionGuard.tryBlock {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error = error {
                    print("[MacKeySwitch] Notification auth error: \(error.localizedDescription)")
                    KeyboardMonitor.notificationsAvailable = false
                    return
                }
                KeyboardMonitor.notificationsAvailable = granted
                print("[MacKeySwitch] Notifications authorized: \(granted)")
            }
        }
        if !ok {
            print("[MacKeySwitch] UNUserNotificationCenter unavailable in this bundle — disabling notifications.")
            KeyboardMonitor.notificationsAvailable = false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        layoutObserverTimer?.invalidate()
        undoHotkey.unregister()
        monitor.stop()
    }

    /// Critical for menu-bar apps: don't quit when the Settings window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Global Undo Hotkey (Carbon-based)

    private let undoHotkey = CarbonHotkey()
    private var hotkeyCancellables = Set<AnyCancellable>()

    /// Register the system-wide undo hotkey via Carbon. Re-registers automatically
    /// when the user changes keyCode/modifiers in Settings.
    private func setupGlobalUndoHotkey() {
        undoHotkey.onFire = { [weak self] in self?.handleUndoHotkey() }
        refreshUndoHotkey()

        // Re-register on change. CombineLatest fires once on subscribe, which is fine
        // (idempotent — register() unregisters prior ref first).
        Publishers.CombineLatest(settings.$undoHotkeyKeyCode, settings.$undoHotkeyModifiers)
            .dropFirst() // skip initial sink on subscribe — we already called refresh above
            .sink { [weak self] _, _ in self?.refreshUndoHotkey() }
            .store(in: &hotkeyCancellables)
    }

    private func refreshUndoHotkey() {
        guard settings.undoHotkeyIsEnabled else {
            undoHotkey.unregister()
            print("[LayoutSwitcher] Undo hotkey disabled.")
            return
        }
        let flags = NSEvent.ModifierFlags(rawValue: settings.undoHotkeyModifiers)
        let carbonMods = CarbonHotkey.carbonModifiers(from: flags)
        _ = undoHotkey.register(
            keyCode: UInt32(settings.undoHotkeyKeyCode),
            carbonModifiers: carbonMods
        )
    }

    private func handleUndoHotkey() {
        monitor.undoLastCorrection()
    }

    // MARK: - Layout Observer

    private func startLayoutObserver() {
        layoutObserverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateLayoutIcon()
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
        // Notify monitor about manual layout switches
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChangedForMonitor),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
        updateLayoutIcon()
    }

    @objc private func inputSourceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateLayoutIcon()
        }
    }

    @objc private func inputSourceChangedForMonitor() {
        monitor.notifyManualLayoutSwitch()
    }

    private func updateLayoutIcon() {
        guard let button = statusItem.button else { return }

        if !settings.isEnabled {
            // Disabled: crossed-out icon
            button.title = ""
            button.image = createDisabledImage()
            button.image?.isTemplate = false
            return
        }

        let lang = InputSourceManager.currentLanguage()

        switch lang {
        case .english:
            button.title = ""
            button.image = createBritishFlagImage()
            button.image?.isTemplate = false

        case .ukrainian:
            button.title = ""
            button.image = createUkrainianFlagImage()
            button.image?.isTemplate = false

        case nil:
            button.image = nil
            button.title = "??"
        }
    }

    /// British flag (simplified Union Jack) for menu bar
    private func createBritishFlagImage() -> NSImage {
        let size = NSSize(width: 22, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: 22, height: 14)

        // Blue background
        NSColor(red: 0.0, green: 0.14, blue: 0.47, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()

        // White diagonal cross
        NSColor.white.setStroke()
        let diagPath = NSBezierPath()
        diagPath.lineWidth = 2.5
        diagPath.move(to: NSPoint(x: 0, y: 0))
        diagPath.line(to: NSPoint(x: 22, y: 14))
        diagPath.move(to: NSPoint(x: 22, y: 0))
        diagPath.line(to: NSPoint(x: 0, y: 14))
        diagPath.stroke()

        // Red diagonal cross (thinner)
        NSColor(red: 0.81, green: 0.07, blue: 0.17, alpha: 1.0).setStroke()
        let redDiag = NSBezierPath()
        redDiag.lineWidth = 1.0
        redDiag.move(to: NSPoint(x: 0, y: 0))
        redDiag.line(to: NSPoint(x: 22, y: 14))
        redDiag.move(to: NSPoint(x: 22, y: 0))
        redDiag.line(to: NSPoint(x: 0, y: 14))
        redDiag.stroke()

        // White cross (horizontal + vertical)
        NSColor.white.setFill()
        NSRect(x: 0, y: 5, width: 22, height: 4).fill()
        NSRect(x: 9, y: 0, width: 4, height: 14).fill()

        // Red cross
        NSColor(red: 0.81, green: 0.07, blue: 0.17, alpha: 1.0).setFill()
        NSRect(x: 0, y: 5.5, width: 22, height: 3).fill()
        NSRect(x: 9.5, y: 0, width: 3, height: 14).fill()

        // Border
        NSColor.gray.withAlphaComponent(0.4).setStroke()
        let border = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 21, height: 13),
                                  xRadius: 1.5, yRadius: 1.5)
        border.lineWidth = 0.5
        border.stroke()

        image.unlockFocus()
        return image
    }

    /// Ukrainian flag (blue + yellow)
    private func createUkrainianFlagImage() -> NSImage {
        let size = NSSize(width: 22, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()

        // Blue stripe (top)
        NSColor(red: 0.0, green: 0.35, blue: 0.73, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 7, width: 22, height: 7),
                     xRadius: 1.5, yRadius: 1.5).fill()

        // Yellow stripe (bottom)
        NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 22, height: 7),
                     xRadius: 1.5, yRadius: 1.5).fill()

        // Border
        NSColor.gray.withAlphaComponent(0.3).setStroke()
        let border = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 21, height: 13),
                                  xRadius: 1.5, yRadius: 1.5)
        border.lineWidth = 0.5
        border.stroke()

        image.unlockFocus()
        return image
    }

    /// Disabled icon: gray flag with red strike-through
    private func createDisabledImage() -> NSImage {
        let size = NSSize(width: 22, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()

        // Gray background
        NSColor.gray.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 22, height: 14),
                     xRadius: 1.5, yRadius: 1.5).fill()

        // "AB" text in gray
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.gray.withAlphaComponent(0.6),
        ]
        let text = "AB" as NSString
        text.draw(at: NSPoint(x: 4, y: 2), withAttributes: attrs)

        // Red strike-through
        NSColor.red.withAlphaComponent(0.8).setStroke()
        let strike = NSBezierPath()
        strike.lineWidth = 2.0
        strike.move(to: NSPoint(x: 2, y: 12))
        strike.line(to: NSPoint(x: 20, y: 2))
        strike.stroke()

        // Border
        NSColor.gray.withAlphaComponent(0.4).setStroke()
        let border = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 21, height: 13),
                                  xRadius: 1.5, yRadius: 1.5)
        border.lineWidth = 0.5
        border.stroke()

        image.unlockFocus()
        return image
    }

    // MARK: - Accessibility

    private func tryStartMonitor() {
        // First check without prompting — if already trusted, start immediately.
        if AXIsProcessTrusted() {
            monitor.start()
            return
        }

        // Not trusted — prompt ONCE (not on every poll; repeated prompts can trigger
        // macOS to re-evaluate the process and kill it after the user grants permission).
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        print("[MacKeySwitch] Waiting for Accessibility permission...")
        if let button = statusItem.button {
            button.image = nil
            button.title = "?? \u{26A0}"
        }

        // Poll (without re-prompting) until permission is granted.
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.accessibilityTimer = nil
                print("[MacKeySwitch] Accessibility permission granted!")
                self?.monitor.start()
                self?.updateLayoutIcon()
            }
        }
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateLayoutIcon()

        let menu = NSMenu()
        menu.delegate = self

        let enableItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enableItem.state = settings.isEnabled ? .on : .off
        menu.addItem(enableItem)

        menu.addItem(NSMenuItem.separator())

        let undoItem = NSMenuItem(
            title: "Undo Last Switch",
            action: #selector(undoSwitch),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(undoItem)

        menu.addItem(NSMenuItem.separator())

        let currentLayout = NSMenuItem(
            title: "Current: \(InputSourceManager.currentLanguage()?.rawValue ?? "other")",
            action: nil,
            keyEquivalent: ""
        )
        currentLayout.tag = 100
        currentLayout.isEnabled = false
        menu.addItem(currentLayout)

        let statsItem = NSMenuItem(
            title: "Corrections: \(settings.sessionCorrections)",
            action: nil,
            keyEquivalent: ""
        )
        statsItem.tag = 101
        statsItem.isEnabled = false
        menu.addItem(statsItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit MacKeySwitch",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        settings.isEnabled.toggle()
        monitor.isEnabled = settings.isEnabled
        sender.state = settings.isEnabled ? .on : .off
        updateLayoutIcon()
    }

    @objc private func undoSwitch() {
        monitor.undoLastCorrection()
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(settings: settings)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "MacKeySwitch Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 500))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    @objc private func quitApp() {
        monitor.stop()
        NSApplication.shared.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let layoutItem = menu.item(withTag: 100) {
            layoutItem.title = "Current: \(InputSourceManager.currentLanguage()?.rawValue ?? "other")"
        }
        if let statsItem = menu.item(withTag: 101) {
            statsItem.title = "Corrections: \(settings.sessionCorrections) (total: \(settings.totalCorrections))"
        }
    }
}
