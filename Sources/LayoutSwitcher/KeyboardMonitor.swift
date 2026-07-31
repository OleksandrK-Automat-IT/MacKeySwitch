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

    /// Stamped into every event this app posts, and checked in the tap callback.
    /// The corrections are typed back into the session tap the monitor itself listens on,
    /// so without a marker the app re-reads its own output. `typeString` makes that acute:
    /// it posts unicode on virtual key 0, which is the keycode for "a", so every corrected
    /// character used to look like a fresh letter keystroke.
    private static let syntheticEventMarker: Int64 = 0x4D4B_5357 // 'MKSW'

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Buffer of (keycode, isShifted) for current word
    private var keyBuffer: [(UInt16, Bool)] = []

    /// Password shape of the current run of keystrokes, fed digits as well as letters.
    private var passwordHeuristic = PasswordHeuristic()

    // Track the language when word started
    private var wordStartLayout: Language?

    var isEnabled: Bool = true

    // Serial queue for corrections
    private let correctionQueue = DispatchQueue(label: "com.layoutswitcher.correction")

    // Self-learning: track last correction for undo detection
    private var lastCorrectedWord: String?
    private var lastCorrectionTime: Date?
    private var backspaceCountAfterCorrection: Int = 0

    // Undo support: store original text and layout before correction
    private var lastOriginalText: String?
    private var lastOriginalLayout: Language?

    // Manual layout switch detection: suppress auto-switch for first word after manual switch
    private var lastManualSwitchTime: Date?
    /// Set at word-start when manual switch was recent; forces the current word to skip correction.
    private var skipCurrentWordCorrection: Bool = false

    // Max buffer length — prevents unbounded growth in long URL/password fields
    private let maxBufferLength = 64

    // Lock for fields shared between main (handleEvent) and correctionQueue (performCorrection)
    private let stateLock = NSLock()

    /// True while a correction is being typed. Written on `correctionQueue`, read on the
    /// main thread from `handleEvent`, so every access goes through the lock. Callers must
    /// not already hold `stateLock` — NSLock is not recursive.
    private var _isCorrecting: Bool = false
    private var isCorrecting: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isCorrecting }
        set { stateLock.lock(); _isCorrecting = newValue; stateLock.unlock() }
    }

    // Callback for undo hotkey
    var onUndoRequest: (() -> Void)?

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

        print("[LayoutSwitcher] Monitor active (word-boundary detection, self-learning).")
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

        // Ignore the keystrokes this app posts itself — see `syntheticEventMarker`.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return
        }

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
            handleBackspaceAfterCorrection()

            // Shrink buffer
            if !keyBuffer.isEmpty {
                keyBuffer.removeLast()
            }
            passwordHeuristic.removeLast()
            if keyBuffer.isEmpty {
                wordStartLayout = nil
                passwordHeuristic.reset()
            }
            return
        }

        // Any non-backspace key clears the undo tracking AND the undo-target snapshot.
        // Otherwise the undo hotkey 2 words later would Option+Shift+Left-select the wrong
        // word and replace it with the previous correction's original text.
        clearCorrectionSnapshot()

        // Word boundary — perform correction here (never mid-word)
        if KeyMapping.wordBoundaryKeycodes.contains(keycode) {
            if KeyMapping.correctionTriggerKeycodes.contains(keycode) {
                maybeCorrect(currentLanguage: currentLang)
            }
            resetBuffer()
            return
        }

        // Feed the password heuristic before the letter-only guard below. Doing it after
        // meant the digit and symbol flags could never be set — those keys are not letter
        // keys — so the heuristic never fired at all.
        passwordHeuristic.record(keycode: keycode, isShifted: isShifted)

        guard KeyMapping.isLetterKey(keycode) else { return }

        // Track layout at word start
        if keyBuffer.isEmpty {
            wordStartLayout = currentLang
        }

        keyBuffer.append((keycode, isShifted))

        // Cap buffer length — avoids unbounded growth in fields without spaces (URLs, passwords)
        if keyBuffer.count > maxBufferLength {
            // Treat as non-word — reset quietly, user is probably typing something structural.
            resetBuffer()
        }
    }

    /// Count backspaces immediately after a correction. Enough of them to wipe the word
    /// means the user rejected it, so it becomes an exception.
    private func handleBackspaceAfterCorrection() {
        stateLock.lock()
        let word = lastCorrectedWord
        let time = lastCorrectionTime
        stateLock.unlock()

        guard let lastWord = word, let lastTime = time,
              Date().timeIntervalSince(lastTime) < 5.0 else { return }

        backspaceCountAfterCorrection += 1

        // A correction types the word *and* a trailing space, so erasing the word takes
        // count + 1 backspaces. Comparing against count alone fired one keystroke early,
        // while a letter was still on screen.
        guard backspaceCountAfterCorrection >= lastWord.count + 1 else { return }

        // Record only the corrected form — keeps the exception list free of the
        // gibberish wrong-layout twins.
        settings?.addException(lastWord)
        clearCorrectionSnapshot()
    }

    private func clearCorrectionSnapshot() {
        stateLock.lock()
        let hadSnapshot = lastCorrectedWord != nil || lastOriginalText != nil
        if hadSnapshot {
            lastCorrectedWord = nil
            lastCorrectionTime = nil
            lastOriginalText = nil
            lastOriginalLayout = nil
        }
        stateLock.unlock()
        if hadSnapshot {
            backspaceCountAfterCorrection = 0
        }
    }

    /// Decide whether the just-finished word should be retyped in the other layout.
    private func maybeCorrect(currentLanguage: Language) {
        if skipCurrentWordCorrection {
            debugLog("[LayoutSwitcher] Skipped correction for this word (manual layout switch)")
            return
        }

        let minLen = settings?.minWordLength ?? 2
        guard keyBuffer.count >= minLen,
              !isCorrecting,
              !passwordHeuristic.looksLikePassword else { return }

        let layout = wordStartLayout ?? currentLanguage
        let buffer = keyBuffer
        let threshold = settings?.sensitivity.scoreThreshold
            ?? SettingsModel.Sensitivity.medium.scoreThreshold
        let delayMs = settings?.correctionDelayMs ?? 50
        let notify = settings?.showNotifications ?? false

        // Detection runs here, on the main thread, rather than on the correction queue.
        // It consults NSSpellChecker, which belongs to AppKit's main thread, and a lookup
        // costs ~0.13ms — cheap enough for a word boundary. Deciding before dispatching
        // also lets the correction slot be claimed synchronously, below.
        guard let intended = LanguageDetector.detectIntended(
            keycodes: buffer,
            currentLayout: layout,
            threshold: threshold,
            settings: settings
        ) else {
            return
        }

        let correctText = KeyMapping.reconstruct(keycodes: buffer, language: intended)
        let originalText = KeyMapping.reconstruct(keycodes: buffer, language: layout)

        // Claim the slot before leaving the main thread. Setting it inside performCorrection
        // left a window in which a second word boundary could start a second correction
        // while the first was still queued.
        isCorrecting = true

        correctionQueue.async { [weak self] in
            self?.performCorrection(
                correctText: correctText,
                originalText: originalText,
                from: layout,
                to: intended,
                delayMs: delayMs,
                notify: notify
            )
        }
    }

    // MARK: - Correction

    private func performCorrection(
        correctText: String,
        originalText: String,
        from: Language,
        to: Language,
        delayMs: Int,
        notify: Bool
    ) {
        // isCorrecting was claimed by the caller, on the main thread.
        let delayUs = UInt32(max(delayMs, 50) * 1000)

        debugLog("[LayoutSwitcher] Correcting \(from.rawValue) -> \(to.rawValue): "
                 + "'\(originalText)' -> '\(correctText)'")

        // Wait for the triggering space to fully process
        usleep(50_000)

        // Erase the word and its trailing space with an exact number of backspaces.
        //
        // This used to select the word with Option+Shift+Left, on the theory that letting
        // the text engine find the word start beats counting characters. It does not: the
        // buffer's idea of a word is "letter keys since the last space", and on a US
        // layout several of those keys type punctuation — ';' is Ukrainian 'ж', ',' is 'б',
        // '.' is 'ю'. The text engine breaks a word on that punctuation, so the selection
        // covered only the tail. Typing "pfd;lb" for "завжди" deleted just "lb" and left
        // "pfd;завжди" behind.
        //
        // The count is exact: every buffered keystroke produces exactly one character in
        // either layout (asserted in KeyMappingTests), plus one for the trailing space.
        deleteBackward(characters: originalText.count + 1)

        usleep(delayUs)

        // Switch input source (TIS APIs must run on the main thread)
        DispatchQueue.main.sync {
            InputSourceManager.switchTo(to)
        }

        usleep(delayUs)

        // Retype correct text
        typeString(correctText)
        simulateKey(keycode: KeyMapping.spaceKeycode, flags: [])

        // Publish post-correction state on main, under the lock, so handleEvent
        // never observes a torn view of these fields.
        let now = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            self._isCorrecting = false
            self.lastCorrectedWord = correctText
            self.lastCorrectionTime = now
            self.lastOriginalText = originalText
            self.lastOriginalLayout = from
            self.stateLock.unlock()

            self.backspaceCountAfterCorrection = 0
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
        debugLog("[LayoutSwitcher] Manual layout switch detected, suppressing next word")
    }

    // MARK: - Undo Last Correction

    /// Undo the last auto-correction: delete the corrected word, switch back, retype original.
    func undoLastCorrection() {
        stateLock.lock()
        let originalTextOpt = lastOriginalText
        let originalLayoutOpt = lastOriginalLayout
        let correctionTimeOpt = lastCorrectionTime
        let correctedFormOpt = lastCorrectedWord
        stateLock.unlock()

        // The corrected form is required, not optional: its length is how much text has to
        // be erased before the original can be retyped.
        guard let originalText = originalTextOpt,
              let originalLayout = originalLayoutOpt,
              let correctionTime = correctionTimeOpt,
              let correctedForm = correctedFormOpt, !correctedForm.isEmpty,
              Date().timeIntervalSince(correctionTime) < 10.0 else {
            print("[LayoutSwitcher] Nothing to undo")
            return
        }

        let delayMs = settings?.correctionDelayMs ?? 50

        correctionQueue.async { [weak self] in
            guard let self = self else { return }
            self.isCorrecting = true
            let delayUs = UInt32(max(delayMs, 50) * 1000)

            // Erase the corrected word and its trailing space. Counted, not selected —
            // see performCorrection for why word selection cannot be trusted here.
            self.deleteBackward(characters: correctedForm.count + 1)
            usleep(delayUs)

            // Switch back to original layout (TIS APIs must run on main thread)
            DispatchQueue.main.sync {
                InputSourceManager.switchTo(originalLayout)
            }
            usleep(delayUs)

            // Retype original text + space
            self.typeString(originalText)
            self.simulateKey(keycode: KeyMapping.spaceKeycode, flags: [])
            usleep(5_000)

            DispatchQueue.main.async {
                self.stateLock.lock()
                self._isCorrecting = false
                self.lastOriginalText = nil
                self.lastOriginalLayout = nil
                self.lastCorrectedWord = nil
                self.lastCorrectionTime = nil
                self.stateLock.unlock()

                self.backspaceCountAfterCorrection = 0

                // Record only the corrected form (per user preference).
                if !correctedForm.isEmpty {
                    self.settings?.addException(correctedForm)
                }
            }

            debugLog("[LayoutSwitcher] Undo: restored '\(originalText)' (\(originalLayout.rawValue))")
        }
    }

    // MARK: - Helpers

    private func resetBuffer() {
        keyBuffer.removeAll()
        wordStartLayout = nil
        skipCurrentWordCorrection = false
        passwordHeuristic.reset()
    }

    /// Post an event, stamped so the tap callback can tell it apart from real typing.
    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Press backspace exactly `characters` times.
    private func deleteBackward(characters: Int) {
        guard characters > 0 else { return }
        for _ in 0..<characters {
            simulateKey(keycode: KeyMapping.backspaceKeycode, flags: [])
        }
    }

    private func simulateKey(keycode: UInt16, flags: CGEventFlags) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        post(keyDown)
        usleep(2_000)
        post(keyUp)
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
            post(event)
            usleep(2_000)

            if let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                post(upEvent)
            }
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
