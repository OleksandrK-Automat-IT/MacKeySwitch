import Cocoa
import Carbon
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = KeyboardMonitor()
    private var settingsWindow: NSWindow?
    private let settings = SettingsModel.shared
    private var accessibilityTimer: Timer?
    private var layoutObserverTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        monitor.settings = settings
        monitor.onUndoRequest = { [weak self] in self?.handleUndoHotkey() }
        setupGlobalUndoHotkey()
        tryStartMonitor()
        startLayoutObserver()
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        layoutObserverTimer?.invalidate()
        monitor.stop()
    }

    // MARK: - Global Undo Hotkey (Ctrl+Z by default, configurable)

    private var undoHotkeyTap: CFMachPort?

    private func setupGlobalUndoHotkey() {
        // Ctrl+Shift+Space to undo last switch
        // Registered separately so it works even when monitor is busy
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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if trusted {
            monitor.start()
        } else {
            print("[MacKeySwitch] Waiting for Accessibility permission...")
            if let button = statusItem.button {
                button.image = nil
                button.title = "?? \u{26A0}"
            }
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
