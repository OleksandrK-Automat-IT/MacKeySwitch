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
    /// Set by AppDelegate once the notification authorization request resolves.
    /// Defaults to false until then — prevents any UN call on first run.
    var notificationsAvailable: Bool = false

    /// Stamped into every event this app posts, and checked in the tap callback.
    /// The corrections are typed back into the session tap the monitor itself listens on,
    /// so without a marker the app re-reads its own output. `typeString` makes that acute:
    /// it posts unicode on virtual key 0, which is the keycode for "a", so every corrected
    /// character used to look like a fresh letter keystroke.
    private static let syntheticEventMarker: Int64 = 0x4D4B_5357 // 'MKSW'

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The contiguous run of reconstructable characters immediately before the caret.
    ///
    /// The correction erases that run with a counted run of backspaces, so the buffer must
    /// never claim more (or fewer) characters than are actually on screen. Anything that
    /// breaks the correspondence — a digit, a '-', an arrow key, a mouse click — empties it
    /// rather than silently desynchronising it. See `invalidateBuffer`.
    private var keyBuffer: [Keystroke] = []

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

    /// When this app last selected an input source itself. The layout-change notification
    /// arrives asynchronously and can land after `isCorrecting` has already been cleared,
    /// at which point the app's own switch reads as the user's and suppresses the next
    /// word. A short window closes that race; `isCorrecting` alone could not.
    private var lastSelfSwitchTime: Date?
    private static let selfSwitchGrace: TimeInterval = 1.0

    /// Layout and frontmost app, cached rather than queried per keystroke.
    ///
    /// `TISCopyCurrentKeyboardInputSource` and `NSWorkspace.frontmostApplication` are both
    /// cross-process calls, and this runs on the main thread inside an event tap callback —
    /// where piling up work invites `tapDisabledByTimeout`. Both values change only on a
    /// notification the app already receives.
    private var cachedLayout: Language?
    private var cachedFrontmostBundleID: String?

    /// What the current layout's dead keys do. Cached alongside the layout, and refreshed
    /// with it — probing costs a UCKeyTranslate per buffered key, which is far too much for
    /// an event-tap callback.
    private var cachedDeadKeys = InputSourceManager.DeadKeyProfile()

    /// The last buffered key was a dead key, so it has put nothing on screen yet. The
    /// boundary space will resolve it into one character and be consumed doing so, which
    /// is why the correction must not count a trailing space it can see on screen.
    private var bufferEndsWithDeadKey = false

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

    /// Set when a real keystroke lands after a correction was claimed but before its
    /// backspaces went out. The snapshot of "text behind the caret" is stale at that point,
    /// so the correction aborts rather than erasing characters the user just typed.
    private var _userTypedDuringCorrection: Bool = false

    /// Re-enables a tap the window server disabled (timeout, or Accessibility revoked and
    /// re-granted). A one-shot re-enable inside the callback cannot recover from the
    /// latter — the callback never fires again — so this runs on a timer.
    private var tapHealthTimer: Timer?

    var settings: SettingsModel?

    func start() {
        guard eventTap == nil else { return }

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

        // Seed the caches the tap callback reads. From here on they are notification-driven.
        cachedLayout = InputSourceManager.currentLanguage()
        cachedDeadKeys = InputSourceManager.deadKeyProfile()
        cachedFrontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Mouse clicks move the caret without producing a keystroke, which would leave the
        // buffer describing a run of text that is no longer in front of the caret.
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
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

        tapHealthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("[LayoutSwitcher] Event tap was disabled; re-enabled "
                      + (CGEvent.tapIsEnabled(tap: tap) ? "successfully" : "FAILED — check Accessibility permission"))
            }
        }

        print("[LayoutSwitcher] Monitor active (word-boundary detection, self-learning).")
    }

    func stop() {
        tapHealthTimer?.invalidate()
        tapHealthTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Removing the run loop source is not enough: the Mach port keeps the tap
            // registered with the window server until it is invalidated.
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        resetBuffer()
    }

    deinit {
        stop()
    }

    // MARK: - Cache updates (pushed by AppDelegate's system observers)

    /// The selected keyboard layout changed. Refreshes the cache and, when the change came
    /// from the user rather than from this app, suppresses the next word's correction.
    func layoutDidChange() {
        cachedLayout = InputSourceManager.currentLanguage()
        cachedDeadKeys = InputSourceManager.deadKeyProfile()

        let selfSwitchedRecently = lastSelfSwitchTime.map {
            Date().timeIntervalSince($0) < Self.selfSwitchGrace
        } ?? false
        guard !isCorrecting, !selfSwitchedRecently else { return }

        lastManualSwitchTime = Date()
        // The run in front of the caret was typed in the previous layout; it can no longer
        // be reconstructed as one word.
        resetBuffer()
        debugLog("[LayoutSwitcher] Manual layout switch detected, suppressing next word")
    }

    /// The frontmost application changed. The caret is now somewhere else entirely.
    /// The undo snapshot describes text in the *previous* app; firing the undo hotkey
    /// here would erase unrelated text, so the snapshot must die with the context.
    func frontmostAppDidChange(bundleID: String?) {
        cachedFrontmostBundleID = bundleID
        resetBuffer()
        clearCorrectionSnapshot()
    }

    // MARK: - Event Handling

    func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        // A click can put the caret anywhere. Whatever the buffer described is no longer
        // the text immediately behind it — and neither is the undo snapshot, whose
        // counted backspaces would land wherever the caret is now.
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            resetBuffer()
            clearCorrectionSnapshot()
            return
        }

        guard type == .keyDown else { return }

        // Ignore the keystrokes this app posts itself — see `syntheticEventMarker`.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return
        }

        // A real keystroke while a correction is queued or typing means the caret text no
        // longer matches the snapshot the correction was built from. performCorrection
        // checks this flag once more before its first backspace and aborts.
        stateLock.lock()
        if _isCorrecting { _userTypedDuringCorrection = true }
        stateLock.unlock()

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
           let bundleID = cachedFrontmostBundleID,
           settings.isAppExcluded(bundleID: bundleID) {
            resetBuffer()
            return
        }

        // Only monitor EN or UA layouts
        guard let currentLang = cachedLayout else {
            resetBuffer()
            return
        }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isShifted = flags.contains(.maskShift)
        let capsLock = flags.contains(.maskAlphaShift)

        // --- Self-learning: detect undo pattern ---
        // If user presses backspace right after a correction, they're undoing it
        if keycode == KeyMapping.backspaceKeycode {
            handleBackspaceAfterCorrection()

            // Backspacing over a pending dead key cancels it rather than deleting a
            // character, so the buffer and the screen no longer agree on the count.
            if bufferEndsWithDeadKey {
                invalidateBuffer()
                passwordHeuristic.removeLast()
                return
            }

            // Shrink buffer
            if !keyBuffer.isEmpty {
                keyBuffer.removeLast()
            }
            passwordHeuristic.removeLast()
            if keyBuffer.isEmpty {
                wordStartLayout = nil
            }
            // Keyed on the heuristic's own count, not the buffer's: the buffer also empties
            // when an unbufferable key arrives, and "Ab12" is still one run at that point.
            if passwordHeuristic.printableCount == 0 {
                passwordHeuristic.reset()
            }
            return
        }

        // Any non-backspace key clears the undo tracking AND the undo-target snapshot.
        // Otherwise the undo hotkey 2 words later would erase the wrong word and replace
        // it with the previous correction's original text.
        clearCorrectionSnapshot()

        // Word boundary — perform correction here (never mid-word)
        if KeyMapping.wordBoundaryKeycodes.contains(keycode) {
            if KeyMapping.correctionTriggerKeycodes.contains(keycode) {
                // A pending dead key spends this space resolving itself, so no space
                // reaches the screen and the correction must not count one.
                maybeCorrect(currentLanguage: currentLang, boundaryReachedScreen: !bufferEndsWithDeadKey)
            }
            resetBuffer()
            return
        }

        // Feed the password heuristic before the letter-only guard below. Doing it after
        // meant the digit and symbol flags could never be set — those keys are not letter
        // keys — so the heuristic never fired at all.
        passwordHeuristic.record(keycode: keycode, isShifted: isShifted, capsLock: capsLock)

        // Everything that is not a buffered letter key breaks the buffer's correspondence
        // with the screen, and has to empty it rather than be ignored:
        //
        //   * digits and '-', '=', '\', '/' print a character that is never buffered, so
        //     the backspace count would come up short. "ghbdsn123 " used to erase seven
        //     characters from a ten-character run and leave "ghbdпривіт ".
        //   * arrows, Home/End, forward-delete and Esc move the caret or the text around
        //     it, so the buffered run is no longer what sits behind the caret.
        //
        // Emptying is not the same as resetting: the password heuristic keeps running,
        // because "Ab12cd" is one run of keystrokes even though the digits never buffer.
        guard KeyMapping.isLetterKey(keycode) else {
            invalidateBuffer()
            return
        }

        // A dead key prints nothing until the next keystroke resolves it, and what the two
        // then produce is not something the static map can predict: on US International
        // "'" + "e" is one character (é), "'" + "'" is one ('), "'" + "." is two ('.).
        // Only one case stays reconstructable — the dead key ending the word, resolved by
        // the boundary space into exactly the character the map claims (verified per
        // layout in `deadKeyProfile`). Then the word on screen is intact and only the
        // space is missing, which `boundaryReachedScreen` tells the correction about.
        if bufferEndsWithDeadKey {
            invalidateBuffer()
            return
        }
        if cachedDeadKeys.dead.contains(keycode) {
            guard cachedDeadKeys.resolvedByBoundary.contains(keycode) else {
                invalidateBuffer()
                return
            }
            bufferEndsWithDeadKey = true
        }

        // Track layout at word start. The manual-switch suppression is consumed here —
        // when a letter actually starts a word — not on any first key: a bare space after
        // the switch used to eat the flag and leave the *next* word unprotected.
        if keyBuffer.isEmpty {
            if let manualTime = lastManualSwitchTime {
                if Date().timeIntervalSince(manualTime) < 2.0 {
                    skipCurrentWordCorrection = true
                }
                lastManualSwitchTime = nil
            }
            wordStartLayout = currentLang
        }

        keyBuffer.append(Keystroke(keycode: keycode, shift: isShifted, capsLock: capsLock))

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
    ///
    /// `boundaryReachedScreen` is false when the triggering space was spent resolving a
    /// pending dead key instead of printing: there is no space behind the caret to erase.
    private func maybeCorrect(currentLanguage: Language, boundaryReachedScreen: Bool) {
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
        stateLock.lock()
        _isCorrecting = true
        _userTypedDuringCorrection = false
        stateLock.unlock()

        // The word, plus the trailing space when one actually reached the screen.
        let deleteCount = originalText.count + (boundaryReachedScreen ? 1 : 0)

        correctionQueue.async { [weak self] in
            self?.performCorrection(
                correctText: correctText,
                originalText: originalText,
                deleteCount: deleteCount,
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
        deleteCount: Int,
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

        // Last exit before destructive output: a fast typist may already be into the next
        // word. The backspace count was snapshotted at the boundary, so erasing now would
        // eat the fresh keystrokes. Abort — a missed correction beats mangled text.
        stateLock.lock()
        let dirty = _userTypedDuringCorrection
        if dirty { _isCorrecting = false }
        stateLock.unlock()
        if dirty {
            debugLog("[LayoutSwitcher] Correction aborted: user kept typing")
            return
        }

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
        // either layout (asserted in KeyMappingTests), plus one for the trailing space —
        // except when a dead key ended the word and spent that space resolving itself, in
        // which case no space reached the screen and `deleteCount` already excludes it.
        // Keys that print without buffering empty the buffer instead — see handleEvent.
        deleteBackward(characters: deleteCount)

        usleep(delayUs)

        // Switch input source (TIS APIs must run on the main thread)
        DispatchQueue.main.sync {
            self.lastSelfSwitchTime = Date()
            InputSourceManager.switchTo(to)
        }

        usleep(delayUs)

        // Retype correct text
        let typedFully = typeString(correctText)
        simulateKey(keycode: KeyMapping.spaceKeycode, flags: [])

        // Publish post-correction state on main, under the lock, so handleEvent
        // never observes a torn view of these fields. The undo snapshot is recorded
        // only when every character actually went out: undo deletes
        // `correctedForm.count + 1` characters, and a snapshot longer than what was
        // typed would erase preceding text.
        let now = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            self._isCorrecting = false
            if typedFully {
                self.lastCorrectedWord = correctText
                self.lastCorrectionTime = now
                self.lastOriginalText = originalText
                self.lastOriginalLayout = from
            }
            self.stateLock.unlock()

            self.backspaceCountAfterCorrection = 0
            self.settings?.recordCorrection()
        }

        if notify {
            showNotification(from: from, to: to, word: correctText)
        }
    }

    // MARK: - Undo Last Correction

    /// Undo the last auto-correction: delete the corrected word, switch back, retype original.
    func undoLastCorrection() {
        stateLock.lock()
        let originalTextOpt = lastOriginalText
        let originalLayoutOpt = lastOriginalLayout
        let correctionTimeOpt = lastCorrectionTime
        let correctedFormOpt = lastCorrectedWord
        let busy = _isCorrecting
        stateLock.unlock()

        // A correction still being typed owns the caret; undoing into it would interleave
        // two runs of synthetic keystrokes.
        guard !busy else {
            print("[LayoutSwitcher] Correction in progress, ignoring undo")
            return
        }

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
        isCorrecting = true

        correctionQueue.async { [weak self] in
            guard let self = self else { return }
            let delayUs = UInt32(max(delayMs, 50) * 1000)

            // Erase the corrected word and its trailing space. Counted, not selected —
            // see performCorrection for why word selection cannot be trusted here.
            self.deleteBackward(characters: correctedForm.count + 1)
            usleep(delayUs)

            // Switch back to original layout (TIS APIs must run on main thread)
            DispatchQueue.main.sync {
                self.lastSelfSwitchTime = Date()
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
                self.settings?.addException(correctedForm)
            }

            debugLog("[LayoutSwitcher] Undo: restored '\(originalText)' (\(originalLayout.rawValue))")
        }
    }

    // MARK: - Helpers

    /// Full reset at a word boundary, or when the caret has moved somewhere unknown.
    private func resetBuffer() {
        keyBuffer.removeAll()
        wordStartLayout = nil
        skipCurrentWordCorrection = false
        bufferEndsWithDeadKey = false
        passwordHeuristic.reset()
    }

    /// Drop the reconstructable run but keep the password heuristic going. Used for keys
    /// that print a character the buffer cannot represent, or that move the caret, without
    /// ending the word the user is typing.
    private func invalidateBuffer() {
        keyBuffer.removeAll()
        wordStartLayout = nil
        bufferEndsWithDeadKey = false
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

    /// Types the text with synthetic unicode key events. Returns false if any character
    /// could not be posted — the caller must then not record an undo snapshot, because
    /// the on-screen text is shorter than the snapshot would claim.
    @discardableResult
    private func typeString(_ text: String) -> Bool {
        var complete = true
        for char in text {
            let str = String(char)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                print("[LayoutSwitcher] WARNING: CGEvent allocation failed; typed text is incomplete")
                complete = false
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
        return complete
    }

    private func showNotification(from: Language, to: Language, word: String) {
        let fromLabel = from.rawValue.capitalized
        let toLabel = to.rawValue.capitalized
        DispatchQueue.main.async { [weak self] in
            // Only attempt if authorization resolved successfully at launch.
            guard let self = self, self.notificationsAvailable else { return }

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
