import Cocoa
import Foundation
import UserNotifications
import ObjCExceptionGuard

// Global C callback
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class KeyboardMonitor {
    /// Global flag set by AppDelegate after auth request resolves.
    /// Defaults to false until explicitly set true — prevents any UN call on first run.
    static var notificationsAvailable: Bool = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Buffer of (keycode, isShifted) for current word
    private var keyBuffer: [(UInt16, Bool)] = []
    private var charCount: Int = 0

    // Track the language when word started
    private var wordStartLayout: Language?

    var isEnabled: Bool = true
    private var isCorrecting: Bool = false

    // Early detection: flag set after 3rd char, correction happens at word boundary
    private var pendingSwitch: Language? = nil

    // Serial queue for corrections
    private let correctionQueue = DispatchQueue(label: "com.layoutswitcher.correction")

    // Self-learning: track last correction for undo detection
    private var lastCorrectedWord: String?
    private var lastCorrectionTime: Date?
    private var backspaceCountAfterCorrection: Int = 0

    // Undo support: store original text and layout before correction
    private var lastOriginalText: String?
    private var lastOriginalLayout: Language?
    private var lastCorrectedText: String?

    // Manual layout switch detection: suppress auto-switch for first word after manual switch
    private var lastManualSwitchTime: Date?
    /// Set at word-start when manual switch was recent; forces the current word to skip correction.
    private var skipCurrentWordCorrection: Bool = false

    // Max buffer length — prevents unbounded growth in long URL/password fields
    private let maxBufferLength = 64

    // Lock for fields shared between main (handleEvent) and correctionQueue (performCorrection)
    private let stateLock = NSLock()

    // Callback for undo hotkey
    var onUndoRequest: (() -> Void)?

    // Password detection
    private var hasUpperCase = false
    private var hasLowerCase = false
    private var hasDigit = false
    private var hasSymbol = false

    var settings: SettingsModel?

    func start() {
        let trusted = AXIsProcessTrusted()
        print("[LayoutSwitcher] Accessibility trusted: \(trusted)")
        if !trusted {
            print("[LayoutSwitcher] ERROR: Not trusted. Grant Accessibility permission and restart.")
            return
        }

        if let settings = settings {
            DictionaryManager.shared.addCustomEnglishWords(settings.customEnglishWords)
            DictionaryManager.shared.addCustomUkrainianWords(settings.customUkrainianWords)
            DictionaryManager.shared.reloadCustomDictionaryFiles(
                englishPaths: settings.customEnglishDictionaryPaths,
                ukrainianPaths: settings.customUkrainianDictionaryPaths
            )
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            print("[LayoutSwitcher] ERROR: CGEvent.tapCreate failed.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[LayoutSwitcher] PuntoSwitcher-style monitor active (3-stage detection, self-learning).")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        resetBuffer()
    }

    // MARK: - Event Handling

    func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        guard type == .keyDown else { return }
        let effectiveEnabled = settings?.isEnabled ?? isEnabled
        guard effectiveEnabled else { return }

        let flags = event.flags

        // Skip hotkeys
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            resetBuffer()
            return
        }

        // Per-app exclusion
        if let settings = settings,
           let frontApp = NSWorkspace.shared.frontmostApplication,
           let bundleID = frontApp.bundleIdentifier,
           settings.isAppExcluded(bundleID: bundleID) {
            resetBuffer()
            return
        }

        // Only monitor EN or UA layouts
        guard let currentLang = InputSourceManager.currentLanguage() else {
            resetBuffer()
            return
        }

        // Suppress auto-switching if user manually switched layout recently (within 2s)
        // Take the flag into skipCurrentWordCorrection — it will be cleared at word boundary.
        if keyBuffer.isEmpty, let manualTime = lastManualSwitchTime,
           Date().timeIntervalSince(manualTime) < 2.0 {
            skipCurrentWordCorrection = true
            lastManualSwitchTime = nil
        }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isShifted = flags.contains(.maskShift)

        // --- Self-learning: detect undo pattern ---
        // If user presses backspace right after a correction, they're undoing it
        if keycode == KeyMapping.backspaceKeycode {
            if let lastWord = lastCorrectedWord,
               let lastTime = lastCorrectionTime,
               Date().timeIntervalSince(lastTime) < 5.0 {
                backspaceCountAfterCorrection += 1
                // If they backspaced enough to erase the corrected word, add ONLY
                // the corrected form to exceptions (per user preference — keep the
                // exception list clean, without gibberish wrong-layout twins).
                if backspaceCountAfterCorrection >= lastWord.count {
                    settings?.addException(lastWord)
                    stateLock.lock()
                    lastCorrectedWord = nil
                    lastCorrectionTime = nil
                    backspaceCountAfterCorrection = 0
                    lastOriginalText = nil
                    lastOriginalLayout = nil
                    lastCorrectedText = nil
                    stateLock.unlock()
                }
            }
            // Shrink buffer
            if !keyBuffer.isEmpty {
                keyBuffer.removeLast()
                charCount = max(0, charCount - 1)
            }
            if keyBuffer.isEmpty {
                wordStartLayout = nil
                resetPasswordFlags()
            }
            return
        }

        // Any non-backspace key clears the undo tracking AND the undo-target snapshot.
        // Otherwise Ctrl+Shift+Z 2 words later would Option+Shift+Left-select the wrong word
        // and replace it with the previous correction's original text.
        if lastCorrectedWord != nil || lastOriginalText != nil {
            stateLock.lock()
            lastCorrectedWord = nil
            lastCorrectionTime = nil
            backspaceCountAfterCorrection = 0
            lastOriginalText = nil
            lastOriginalLayout = nil
            lastCorrectedText = nil
            stateLock.unlock()
        }

        // Word boundary — perform correction here (never mid-word)
        if KeyMapping.wordBoundaryKeycodes.contains(keycode) {
            let minLen = settings?.minWordLength ?? 2
            let shouldSkip = skipCurrentWordCorrection
            if !shouldSkip && keyBuffer.count >= minLen && !isCorrecting && !looksLikePassword() {
                let layout = wordStartLayout ?? currentLang
                if let pending = pendingSwitch {
                    // Early detection already decided — use it directly
                    triggerCorrectionWithKnownTarget(layout: layout, intended: pending)
                } else {
                    // No early detection — do full word analysis
                    triggerFullWordCorrection(layout: layout)
                }
            } else if shouldSkip {
                print("[LayoutSwitcher] Skipped correction for this word (manual layout switch detected)")
            }
            resetBuffer()
            return
        }

        // Only buffer letter keys
        guard KeyMapping.isLetterKey(keycode) else { return }

        // Track layout at word start
        if keyBuffer.isEmpty {
            wordStartLayout = currentLang
            resetPasswordFlags()
        }

        // Update password detection flags
        updatePasswordFlags(keycode: keycode, isShifted: isShifted)

        keyBuffer.append((keycode, isShifted))
        charCount += 1

        // Cap buffer length — avoids unbounded growth in fields without spaces (URLs, passwords)
        if keyBuffer.count > maxBufferLength {
            // Treat as non-word — reset quietly, user is probably typing something structural.
            resetBuffer()
            return
        }

        // REAL-TIME: check after 3rd character using impossible bigrams
        if charCount >= 3 && !isCorrecting && !looksLikePassword() {
            let layout = wordStartLayout ?? currentLang
            checkEarlyDetection(layout: layout)
        }
    }

    // MARK: - Password Detection

    private func resetPasswordFlags() {
        hasUpperCase = false
        hasLowerCase = false
        hasDigit = false
        hasSymbol = false
    }

    private func updatePasswordFlags(keycode: UInt16, isShifted: Bool) {
        if isShifted {
            hasUpperCase = true
        } else {
            hasLowerCase = true
        }
        // Number row keycodes
        let numberKeys: Set<UInt16> = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        if numberKeys.contains(keycode) {
            if isShifted {
                hasSymbol = true
            } else {
                hasDigit = true
            }
        }
    }

    /// Passwords typically have mixed case + digits + symbols, 6+ chars
    private func looksLikePassword() -> Bool {
        charCount >= 6 && hasUpperCase && hasLowerCase && (hasDigit || hasSymbol)
    }

    // MARK: - Early Detection (after 3rd char — sets flag, correction at word boundary)

    private func checkEarlyDetection(layout: Language) {
        guard let intended = LanguageDetector.detectEarly(
            keycodes: keyBuffer,
            currentLayout: layout,
            settings: settings
        ) else {
            // Reset pending if new chars invalidate it
            pendingSwitch = nil
            return
        }

        let enText = KeyMapping.reconstruct(keycodes: keyBuffer, language: .english)
        let uaText = KeyMapping.reconstruct(keycodes: keyBuffer, language: .ukrainian)
        print("[LayoutSwitcher] Early detect after \(charCount) chars: \(layout.rawValue) -> \(intended.rawValue) (EN='\(enText)' UA='\(uaText)')")

        // Just set the flag — actual correction happens at word boundary
        pendingSwitch = intended
    }

    // MARK: - Correction with known target (from early detection)

    private func triggerCorrectionWithKnownTarget(layout: Language, intended: Language) {
        let buffer = keyBuffer
        let count = charCount
        let delayMs = settings?.correctionDelayMs ?? 50
        let notify = settings?.showNotifications ?? false
        let correctText = KeyMapping.reconstruct(keycodes: buffer, language: intended)
        let originalText = KeyMapping.reconstruct(keycodes: buffer, language: layout)

        print("[LayoutSwitcher] Correcting (early-flagged): \(layout.rawValue) -> \(intended.rawValue): '\(correctText)'")

        correctionQueue.async { [weak self] in
            self?.performCorrection(
                count: count,
                correctText: correctText,
                originalText: originalText,
                from: layout,
                to: intended,
                delayMs: delayMs,
                notify: notify,
                addSpace: true
            )
        }
    }

    // MARK: - Full Word Correction (on word boundary)

    private func triggerFullWordCorrection(layout: Language) {
        let buffer = keyBuffer
        let count = charCount
        let delayMs = settings?.correctionDelayMs ?? 50
        let notify = settings?.showNotifications ?? false

        correctionQueue.async { [weak self] in
            guard let self = self else { return }

            guard let intended = LanguageDetector.detectIntended(
                keycodes: buffer,
                currentLayout: layout,
                settings: self.settings
            ) else {
                return
            }

            let correctText = KeyMapping.reconstruct(keycodes: buffer, language: intended)
            let originalText = KeyMapping.reconstruct(keycodes: buffer, language: layout)
            print("[LayoutSwitcher] FULL switch: \(layout.rawValue) -> \(intended.rawValue): '\(correctText)'")

            self.performCorrection(
                count: count,
                correctText: correctText,
                originalText: originalText,
                from: layout,
                to: intended,
                delayMs: delayMs,
                notify: notify,
                addSpace: true
            )
        }
    }

    // MARK: - Correction

    private func performCorrection(
        count: Int,
        correctText: String,
        originalText: String,
        from: Language,
        to: Language,
        delayMs: Int,
        notify: Bool,
        addSpace: Bool
    ) {
        isCorrecting = true
        let delayUs = UInt32(max(delayMs, 50) * 1000)

        // Wait for the triggering keystroke (space/letter) to fully process
        usleep(50_000)

        // Use Cmd+A-style word selection: Shift+Option+Left selects whole word backward
        // This is more reliable than counting characters
        if addSpace {
            // Delete trailing space first
            simulateKey(keycode: KeyMapping.backspaceKeycode, flags: [])
            usleep(10_000)
        }

        // Select the whole word backward with Option+Shift+Left (selects by word)
        simulateKey(keycode: 0x7B, flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlternate.rawValue))
        usleep(10_000)

        // Delete the selection
        simulateKey(keycode: KeyMapping.backspaceKeycode, flags: [])

        usleep(delayUs)

        // Switch input source (TIS APIs must run on the main thread)
        DispatchQueue.main.sync {
            InputSourceManager.switchTo(to)
        }

        usleep(delayUs)

        // Retype correct text
        typeString(correctText)
        if addSpace {
            simulateKey(keycode: 0x31, flags: []) // space
        }

        // Publish post-correction state on main, under the lock, so handleEvent
        // never observes a torn view of these fields.
        let now = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            self.isCorrecting = false
            self.lastCorrectedWord = correctText
            self.lastCorrectedText = correctText
            self.lastCorrectionTime = now
            self.backspaceCountAfterCorrection = 0
            self.lastOriginalText = originalText
            self.lastOriginalLayout = from
            self.stateLock.unlock()

            self.settings?.recordCorrection()
        }

        if notify {
            showNotification(from: from, to: to, word: correctText)
        }
    }

    // MARK: - Manual Layout Switch Detection

    /// Called when the system detects a keyboard layout change (via DistributedNotificationCenter).
    /// If monitor is NOT in the middle of a correction, this is a manual switch by the user.
    func notifyManualLayoutSwitch() {
        guard !isCorrecting else { return }
        lastManualSwitchTime = Date()
        print("[LayoutSwitcher] Manual layout switch detected, will suppress auto-switch for next word")
    }

    // MARK: - Undo Last Correction

    /// Undo the last auto-correction: delete the corrected word, switch back, retype original.
    func undoLastCorrection() {
        stateLock.lock()
        let originalTextOpt = lastOriginalText
        let originalLayoutOpt = lastOriginalLayout
        let correctionTimeOpt = lastCorrectionTime
        stateLock.unlock()

        guard let originalText = originalTextOpt,
              let originalLayout = originalLayoutOpt,
              let correctionTime = correctionTimeOpt,
              Date().timeIntervalSince(correctionTime) < 10.0 else {
            print("[LayoutSwitcher] Nothing to undo")
            return
        }

        let delayMs = settings?.correctionDelayMs ?? 50

        correctionQueue.async { [weak self] in
            guard let self = self else { return }
            self.isCorrecting = true
            let delayUs = UInt32(max(delayMs, 50) * 1000)

            // Select the corrected word + trailing space backward
            self.simulateKey(keycode: 0x7B, flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlternate.rawValue))
            usleep(10_000)

            // Delete the selection
            self.simulateKey(keycode: KeyMapping.backspaceKeycode, flags: [])
            usleep(delayUs)

            // Switch back to original layout (TIS APIs must run on main thread)
            DispatchQueue.main.sync {
                InputSourceManager.switchTo(originalLayout)
            }
            usleep(delayUs)

            // Retype original text + space
            self.typeString(originalText)
            self.simulateKey(keycode: 0x31, flags: []) // space
            usleep(5_000)

            // Snapshot corrected form then clear all undo state atomically on main thread
            DispatchQueue.main.async {
                self.stateLock.lock()
                let correctedForm = self.lastCorrectedWord ?? ""
                self.isCorrecting = false
                self.lastOriginalText = nil
                self.lastOriginalLayout = nil
                self.lastCorrectedText = nil
                self.lastCorrectedWord = nil
                self.lastCorrectionTime = nil
                self.stateLock.unlock()

                // Add ONLY the corrected form to exceptions (per user preference).
                if !correctedForm.isEmpty {
                    self.settings?.addException(correctedForm)
                }
            }

            print("[LayoutSwitcher] Undo: restored '\(originalText)' (\(originalLayout.rawValue)), added to exceptions")
        }
    }

    // MARK: - Helpers

    private func resetBuffer() {
        keyBuffer.removeAll()
        charCount = 0
        wordStartLayout = nil
        pendingSwitch = nil
        skipCurrentWordCorrection = false
        resetPasswordFlags()
    }

    private func simulateKey(keycode: UInt16, flags: CGEventFlags) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        usleep(2_000)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        usleep(5_000)
    }

    private func typeString(_ text: String) {
        for char in text {
            let str = String(char)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                continue
            }
            let utf16 = Array(str.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cgAnnotatedSessionEventTap)
            usleep(2_000)

            let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            upEvent?.post(tap: .cgAnnotatedSessionEventTap)
            usleep(5_000)
        }
    }

    private func showNotification(from: Language, to: Language, word: String) {
        // Only attempt if authorization resolved successfully at launch.
        guard KeyboardMonitor.notificationsAvailable else { return }

        let fromLabel = from.rawValue.capitalized
        let toLabel = to.rawValue.capitalized
        DispatchQueue.main.async {
            // Guard against NSInternalInconsistencyException on ad-hoc / unsigned bundles.
            _ = ObjCExceptionGuard.tryBlock {
                let content = UNMutableNotificationContent()
                content.title = "MacKeySwitch"
                content.body = "\(fromLabel) \u{2192} \(toLabel): \(word)"
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        print("[MacKeySwitch] Notification post error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
