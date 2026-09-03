import Cocoa
import Carbon
import Combine
import SwiftUI
import UserNotifications
import ObjCExceptionGuard

/// A window Escape closes.
///
/// Escape reaches a window as `cancelOperation(_:)`, but only after the responder chain
/// has had it: a text field being edited answers first and ends its own editing, so
/// Escape backs out of a half-typed exception word before it closes anything.
///
/// `onCancel` exists to make that testable without a running app; it defaults to closing.
final class EscapeClosableWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel = onCancel {
            onCancel()
        } else {
            close()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = KeyboardMonitor()
    private var settingsWindow: NSWindow?
    private let settings = SettingsModel.shared
    private var accessibilityTimer: Timer?
    /// Backstop for the menu-bar flag. The distributed layout notification is the primary
    /// signal but is not reliable; one TIS read a second costs microseconds.
    private var layoutIconTimer: Timer?
    /// Held so the checkmark can follow `settings.isEnabled` however it was changed.
    private weak var enableMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set runtime app icon (Dock/About/Alerts) to match the About-tab logo.
        NSApp.applicationIconImage = AppIconRenderer.makeAppIcon(size: 512)

        setupStatusBar()
        monitor.settings = settings
        monitor.onSelfInitiatedLayoutSwitch = { [weak self] in self?.updateLayoutIcon() }
        setupGlobalUndoHotkey()
        observeEnabledSetting()
        observePairSetting()
        observeInterfaceLanguage()
        requestNotificationAuthorization()
        // Observers before the monitor: the monitor seeds its caches at start, and a layout
        // or app switch in between would otherwise go unseen.
        startSystemObservers()
        tryStartMonitor()
    }

    /// macOS 14 logs a warning for delegates that do not answer this; secure coding is the
    /// only sensible answer for an app with no restorable UI state.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
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
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                // The callback arrives on an arbitrary thread; the flag it sets is read
                // from the main thread on every correction.
                DispatchQueue.main.async {
                    if let error = error {
                        print("[MacKeySwitch] Notification auth error: \(error.localizedDescription)")
                        self?.monitor.notificationsAvailable = false
                        return
                    }
                    self?.monitor.notificationsAvailable = granted
                    print("[MacKeySwitch] Notifications authorized: \(granted)")
                }
            }
        }
        if !ok {
            print("[MacKeySwitch] UNUserNotificationCenter unavailable in this bundle — disabling notifications.")
            monitor.notificationsAvailable = false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        layoutIconTimer?.invalidate()
        undoHotkey.unregister()
        selectionHotkey.unregister()
        correctWordHotkey.unregister()
        monitor.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Critical for menu-bar apps: don't quit when the Settings window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Global Undo Hotkey (Carbon-based)

    private let undoHotkey = CarbonHotkey()
    private let selectionHotkey = CarbonHotkey()
    private let correctWordHotkey = CarbonHotkey()
    private var cancellables = Set<AnyCancellable>()

    /// Register the system-wide undo hotkey via Carbon. Re-registers automatically
    /// when the user records a different shortcut in Settings.
    private func setupGlobalUndoHotkey() {
        undoHotkey.onFire = { [weak self] in self?.handleUndoHotkey() }

        // The binding is taken from the publisher, never read back off `settings`:
        // `@Published` emits before the stored property is updated, so reading the model
        // inside this sink would apply the *previous* shortcut. `sink` on subscribe covers
        // the initial registration, so there is no separate call for it.
        correctWordHotkey.onFire = { [weak self] in self?.monitor.correctLastWordOnDemand() }
        selectionHotkey.onFire = { [weak self] in self?.handleSelectionHotkey() }

        // Treat the three shortcuts as one registry. If two collide, one registration
        // fails; when either binding changes later, unregistering and retrying all three
        // makes the previously blocked shortcut live again automatically.
        Publishers.CombineLatest3(
            settings.$undoHotkey,
            settings.$correctWordHotkey,
            settings.$selectionHotkey
        )
            .sink { [weak self] undo, correctWord, selection in
                guard let self = self else { return }
                self.undoHotkey.unregister()
                self.correctWordHotkey.unregister()
                self.selectionHotkey.unregister()
                self.applyUndoHotkey(undo)
                self.applyCorrectWordHotkey(correctWord)
                self.applySelectionHotkey(selection)
            }
            .store(in: &cancellables)
    }

    private func applyCorrectWordHotkey(_ binding: HotkeyBinding) {
        guard binding.isEnabled else {
            correctWordHotkey.unregister()
            settings.setHotkeyRegistration(.correctWord, binding: binding, succeeded: true)
            print("[LayoutSwitcher] Correct-word hotkey disabled.")
            return
        }
        let flags = NSEvent.ModifierFlags(rawValue: binding.modifiers)
        let succeeded = correctWordHotkey.register(
            keyCode: UInt32(binding.keyCode),
            carbonModifiers: CarbonHotkey.carbonModifiers(from: flags)
        )
        settings.setHotkeyRegistration(.correctWord, binding: binding, succeeded: succeeded)
    }

    private func applySelectionHotkey(_ binding: HotkeyBinding) {
        guard binding.isEnabled else {
            selectionHotkey.unregister()
            settings.setHotkeyRegistration(.selection, binding: binding, succeeded: true)
            debugLog("[LayoutSwitcher] selection hotkey disabled")
            return
        }
        let flags = NSEvent.ModifierFlags(rawValue: binding.modifiers)
        let succeeded = selectionHotkey.register(
            keyCode: UInt32(binding.keyCode),
            carbonModifiers: CarbonHotkey.carbonModifiers(from: flags)
        )
        settings.setHotkeyRegistration(.selection, binding: binding, succeeded: succeeded)
    }

    private func handleSelectionHotkey() {
        // The conversion selects an input source. Claim it up front so the monitor does not
        // read the resulting notification as a manual switch.
        monitor.noteSelfInitiatedLayoutSwitch()
        SelectionCorrector.correctSelection { [weak self] result in
            switch result {
            case .success:
                self?.settings.recordCorrection()
                self?.updateLayoutIcon()
            case .failure(let reason):
                debugLog("[LayoutSwitcher] selection skipped: \(reason)")
            }
        }
    }

    private func applyUndoHotkey(_ binding: HotkeyBinding) {
        guard binding.isEnabled else {
            undoHotkey.unregister()
            settings.setHotkeyRegistration(.undo, binding: binding, succeeded: true)
            print("[LayoutSwitcher] Undo hotkey disabled.")
            return
        }
        let flags = NSEvent.ModifierFlags(rawValue: binding.modifiers)
        let carbonMods = CarbonHotkey.carbonModifiers(from: flags)
        let succeeded = undoHotkey.register(
            keyCode: UInt32(binding.keyCode),
            carbonModifiers: carbonMods
        )
        settings.setHotkeyRegistration(.undo, binding: binding, succeeded: succeeded)
    }

    private func handleUndoHotkey() {
        monitor.undoLastCorrection()
    }

    // MARK: - Enabled State

    /// Keep the menu bar in step with the toggle in the Settings window. Without this the
    /// icon kept showing a flag, and the menu kept showing a checkmark, after the user had
    /// switched the app off anywhere other than the menu itself.
    private func observeEnabledSetting() {
        settings.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                self.enableMenuItem?.state = enabled ? .on : .off
                self.updateLayoutIcon()
            }
            .store(in: &cancellables)
    }

    /// The pin lives in the layout code as a plain static, so it is set from here rather
    /// than read through the settings object on every word.
    private func observePairSetting() {
        settings.$cyrillicPair
            .receive(on: DispatchQueue.main)
            .sink { pair in InputSourceManager.pinnedCyrillic = pair.language }
            .store(in: &cancellables)
    }

    // MARK: - Interface Language

    /// SwiftUI redraws itself when the language changes; an `NSMenu` does not. Its titles
    /// were baked in when it was built, so the menu has to be rebuilt by hand.
    private func observeInterfaceLanguage() {
        Localization.shared.$language
            .dropFirst() // the menu is already built in the current language
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.statusItem.menu = self.buildMenu()
                self.updateLayoutIcon()
                // The window is created once and kept, so its title was baked in too.
                self.settingsWindow?.title = L("window.settings")
            }
            .store(in: &cancellables)
    }



    // MARK: - System Observers

    /// The monitor reads the current layout and the frontmost app on every keystroke, so
    /// both are cached there and refreshed from here. Querying them per keystroke meant two
    /// cross-process calls inside an event tap callback, which is how a tap earns
    /// `tapDisabledByTimeout`.
    private func startSystemObservers() {
        // One observer drives both effects. Registering the same notification twice ran
        // the whole dispatch twice per switch for no benefit.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        layoutIconTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateLayoutIcon()
        }
        updateLayoutIcon()
    }

    @objc private func inputSourceChanged() {
        // Distributed notifications are not guaranteed to arrive on the main thread, and
        // everything downstream — TIS, the status item, the monitor's buffer — is main-only.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.monitor.layoutDidChange()
            self.updateLayoutIcon()
        }
    }

    @objc private func frontmostAppChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        monitor.frontmostAppDidChange(bundleID: app?.bundleIdentifier)
    }

    /// What the menu-bar item is currently showing, so a refresh that changes nothing —
    /// the 1s backstop timer, mostly — does not redraw a bezier-path flag and reassign the
    /// button's image every second for the life of the process.
    private enum IconState: Equatable {
        case disabled, needsAccessibility, english, ukrainian, other(String)
    }
    private var shownIconState: IconState?

    /// Drawn once each; the flags never change.
    private lazy var britishFlagImage = createBritishFlagImage()
    private lazy var ukrainianFlagImage = createUkrainianFlagImage()
    private lazy var disabledImage = createDisabledImage()

    private func updateLayoutIcon() {
        guard let button = statusItem.button else { return }

        let state: IconState
        if !settings.isEnabled {
            state = .disabled
        } else if !monitor.isRunning {
            // Without the tap nothing works, and the reason is always the Accessibility
            // grant. The warning used to be written straight to the button, where the
            // periodic refresh replaced it with a flag within a second.
            state = .needsAccessibility
        } else {
            switch InputSourceManager.currentLanguage() {
            case .english: state = .english
            case .ukrainian: state = .ukrainian
            // Shown the way any other layout is, from its language tag — the same badge
            // this layout had before it was corrected for.
            case .russian, nil:
                state = .other(Self.badge(forOtherLayout: InputSourceManager.currentSourceLanguageTag()))
            }
        }
        guard state != shownIconState else { return }
        shownIconState = state

        switch state {
        case .disabled:
            button.title = ""
            button.image = disabledImage
            button.image?.isTemplate = false

        case .needsAccessibility:
            button.image = nil
            button.title = "?? \u{26A0}"

        case .english:
            button.title = ""
            button.image = britishFlagImage
            button.image?.isTemplate = false

        case .ukrainian:
            button.title = ""
            button.image = ukrainianFlagImage
            button.image?.isTemplate = false

        case .other(let badge):
            // Some other layout. Show its country's flag rather than the "??" that used to
            // sit here — it said only "not one of the two", when what the user wants to know
            // is which layout is actually active.
            if let image = Self.badgeImage(badge) {
                // Rendered into an image the same size as the drawn flags, rather than set
                // as the button's title: emoji and text have different metrics, so the
                // status item would change width and baseline every time the user switched
                // between a corrected layout and any other.
                // `isTemplate` is decided in badgeImage — flags keep their colours, the
                // text fallback has to adapt to the menu bar's theme.
                button.title = ""
                button.image = image
            } else {
                button.image = nil
                button.title = badge
            }
        }
    }

    /// Draw a badge into the same 22x14 box the hand-drawn flags use.
    static func badgeImage(_ badge: String) -> NSImage? {
        guard !badge.isEmpty else { return nil }
        let size = NSSize(width: 22, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        // Flags are wide glyphs and plain codes are narrow ones, so the text is measured and
        // scaled to fit rather than set at a fixed point size.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13)
        ]
        var measured = (badge as NSString).size(withAttributes: attributes)
        if measured.width > size.width || measured.height > size.height {
            let scale = min(size.width / measured.width, size.height / measured.height)
            attributes[.font] = NSFont.systemFont(ofSize: 13 * scale)
            measured = (badge as NSString).size(withAttributes: attributes)
        }

        let origin = NSPoint(
            x: (size.width - measured.width) / 2,
            y: (size.height - measured.height) / 2
        )
        (badge as NSString).draw(at: origin, withAttributes: attributes)

        // A flag carries its own colours and must be drawn as-is. The text fallback must
        // not: it is drawn in black, and a non-template black glyph is invisible against a
        // dark menu bar. As a template, macOS tints it to match the bar in either theme.
        image.isTemplate = !Self.isFlagEmoji(badge)
        return image
    }

    /// Whether a badge is a flag, i.e. begins with a regional indicator symbol.
    static func isFlagEmoji(_ badge: String) -> Bool {
        guard let first = badge.unicodeScalars.first else { return false }
        return (0x1F1E6...0x1F1FF).contains(first.value)
    }

    /// Menu-bar text for a layout this app does not correct: the country's flag, or the
    /// language code when the language is outside the table, or "?" when the input source
    /// declares no language at all.
    static func badge(forOtherLayout tag: String?) -> String {
        guard let tag = tag, !tag.isEmpty else { return "?" }
        return LayoutFlag.emoji(forLanguageTag: tag) ?? LayoutFlag.fallbackLabel(forLanguageTag: tag)
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
            // The icon was drawn before the tap existed and shows the permission warning;
            // without this it stays there until the periodic refresh, a visible flash at
            // every launch.
            updateLayoutIcon()
            return
        }

        // Not trusted — prompt ONCE (not on every poll; repeated prompts can trigger
        // macOS to re-evaluate the process and kill it after the user grants permission).
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        print("[MacKeySwitch] Waiting for Accessibility permission...")
        updateLayoutIcon()

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
        statusItem.menu = buildMenu()
        updateLayoutIcon()
    }

    /// Build the menu from scratch, in the current interface language.
    ///
    /// Separate from `setupStatusBar` because the language observer needs to replace the
    /// menu: calling the setup again would ask `NSStatusBar` for a *second* status item and
    /// leave two icons side by side in the menu bar.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let enableItem = NSMenuItem(
            title: L("menu.enabled"),
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enableItem.state = settings.isEnabled ? .on : .off
        menu.addItem(enableItem)
        enableMenuItem = enableItem

        menu.addItem(NSMenuItem.separator())

        let undoItem = NSMenuItem(
            title: L("menu.undo"),
            action: #selector(undoSwitch),
            keyEquivalent: ""
        )
        undoItem.tag = 102
        menu.addItem(undoItem)
        syncUndoMenuItem(undoItem)

        menu.addItem(NSMenuItem.separator())

        let currentLayout = NSMenuItem(
            title: L("menu.currentLayout", LayoutFlag.currentLayoutDisplayName),
            action: nil,
            keyEquivalent: ""
        )
        currentLayout.tag = 100
        currentLayout.isEnabled = false
        menu.addItem(currentLayout)

        // The pair as a submenu, mirroring the picker in Settings → General.
        let pairItem = NSMenuItem(title: L("menu.pair"), action: nil, keyEquivalent: "")
        pairItem.tag = 103
        let pairMenu = NSMenu()
        for pair in SettingsModel.CyrillicPair.allCases {
            let item = NSMenuItem(title: pair.label, action: #selector(selectPair(_:)), keyEquivalent: "")
            item.tag = pair.rawValue
            item.target = self
            pairMenu.addItem(item)
        }
        pairItem.submenu = pairMenu
        syncPairMenu(pairMenu)
        menu.addItem(pairItem)

        let statsItem = NSMenuItem(
            title: L("menu.corrections", settings.sessionCorrections),
            action: nil,
            keyEquivalent: ""
        )
        statsItem.tag = 101
        statsItem.isEnabled = false
        menu.addItem(statsItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: L("menu.settings"),
            action: #selector(openSettings),
            keyEquivalent: ","
        ))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: L("menu.quit"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        return menu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        // The checkmark, the monitor and the icon all follow from `observeEnabledSetting`,
        // so this only has to flip the setting.
        settings.isEnabled.toggle()
    }

    @objc private func undoSwitch() {
        monitor.undoLastCorrection()
    }

    @objc private func selectPair(_ sender: NSMenuItem) {
        guard let pair = SettingsModel.CyrillicPair(rawValue: sender.tag) else { return }
        settings.cyrillicPair = pair
    }

    private func syncPairMenu(_ pairMenu: NSMenu) {
        for item in pairMenu.items {
            item.state = item.tag == settings.cyrillicPair.rawValue ? .on : .off
        }
    }

    /// Mirror the shortcut the Carbon hotkey is actually registered with. The menu item
    /// used to hardcode ⌃⇧Z, so it advertised the wrong shortcut as soon as the user
    /// recorded a different one in Settings.
    private func syncUndoMenuItem(_ item: NSMenuItem) {
        let binding = settings.undoHotkey
        guard binding.isEnabled else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        let label = HotkeyBinding.keyCodeLabel(UInt16(binding.keyCode))
        // Only single characters work as a key equivalent; anything else is left blank
        // and the hotkey still works globally through Carbon.
        item.keyEquivalent = label.count == 1 ? label.lowercased() : ""
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: binding.modifiers)
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(settings: settings)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = EscapeClosableWindow(contentViewController: hostingController)
        window.title = L("window.settings")
        // Resizable on purpose. The window is sized for the longest translation the app
        // ships with, but that width comes from measuring strings rather than from AppKit's
        // own tab metrics, so it is an estimate with headroom. Letting the user widen the
        // window turns any residual mis-estimate into an annoyance instead of permanently
        // truncated tab titles. The view's `minWidth` stops it being shrunk back into one.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Sized from the view rather than a second hardcoded pair of numbers — the two
        // used to disagree by 40×80pt, which showed up as dead margin around the tabs.
        window.setContentSize(SettingsView.preferredSize)
        window.contentMinSize = SettingsView.preferredSize
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
        enableMenuItem?.state = settings.isEnabled ? .on : .off
        if let layoutItem = menu.item(withTag: 100) {
            layoutItem.title = L("menu.currentLayout", LayoutFlag.currentLayoutDisplayName)
        }
        if let statsItem = menu.item(withTag: 101) {
            statsItem.title = L("menu.correctionsWithTotal", settings.sessionCorrections, settings.totalCorrections)
        }
        if let undoItem = menu.item(withTag: 102) {
            syncUndoMenuItem(undoItem)
        }
        if let pairMenu = menu.item(withTag: 103)?.submenu {
            syncPairMenu(pairMenu)
        }
    }
}
