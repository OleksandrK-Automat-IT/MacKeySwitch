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

/// The machinery around `CorrectionEngine`: the event tap, the cross-thread flags, and the
/// synthetic keystrokes that carry out a plan. Every *decision* is the engine's.
final class KeyboardMonitor {
    /// Set by AppDelegate once the notification authorization request resolves.
    var notificationsAvailable: Bool = false

    /// Stamped into every event this app posts, and checked in the tap callback.
    /// The corrections are typed back into the session tap the monitor itself listens on,
    /// so without a marker the app re-reads its own output. `typeString` makes that acute:
    /// it posts unicode on virtual key 0, which is the keycode for "a", so every corrected
    /// character used to look like a fresh letter keystroke.
    static let syntheticEventMarker: Int64 = 0x4D4B_5357 // 'MKSW'

    let engine: CorrectionEngine

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Serial queue for typing out plans.
    private let correctionQueue = DispatchQueue(label: "com.layoutswitcher.correction")

    /// Guards the two flags shared between the main thread and `correctionQueue`.
    private let stateLock = NSLock()

    /// True while a plan is being typed. Written on `correctionQueue`, read on the main
    /// thread, so every access goes through the lock. NSLock is not recursive.
    private var _isCorrecting: Bool = false
    private var isCorrecting: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isCorrecting }
    }

    /// Set when anything invalidates a plan after it was claimed but before its backspaces
    /// went out: a real keystroke, or a switch to another app. The snapshot of "text behind
    /// the caret" is stale then, and the backspaces would land on text the plan does not
    /// describe — in another app's window, in the worst case. The plan aborts instead.
    private var _correctionContextDirty: Bool = false

    /// Re-enables a tap the window server disabled (timeout, or Accessibility revoked and
    /// re-granted). A one-shot re-enable inside the callback cannot recover from the
    /// latter — the callback never fires again — so this runs on a timer.
    private var tapHealthTimer: Timer?

    var settings: SettingsModel? {
        didSet { engine.settings = settings ?? Self.noSettings }
    }

    /// Whether the event tap is installed — false until Accessibility is granted.
    var isRunning: Bool { eventTap != nil }

    /// Fired on the main thread right after this app selects an input source itself. The
    /// menu-bar flag hangs off this rather than waiting for the distributed notification,
    /// which is late often enough to leave the flag showing the previous layout.
    var onSelfInitiatedLayoutSwitch: (() -> Void)?

    init() {
        engine = CorrectionEngine(
            environment: LiveCorrectionEnvironment(),
            settings: Self.noSettings,
            dictionary: DictionaryManager.shared
        )
    }

    /// What the engine runs against before AppDelegate hands over the real model.
    private struct NoSettings: CorrectionSettings {
        let isEnabled = true
        let minWordLength = 2
        let scoreThreshold = SettingsModel.Sensitivity.medium.scoreThreshold
        let correctionMode = SettingsModel.CorrectionMode.automatic
        func isAppExcluded(bundleID: String) -> Bool { false }
        func isException(_ word: String) -> Bool { false }
        func isMacKeySwitchHotkey(
            keycode: UInt16, shift: Bool, command: Bool, control: Bool, option: Bool
        ) -> Bool {
            guard control, shift, !command, !option else { return false }
            return [UInt16(0x06), UInt16(0x07), KeyMapping.spaceKeycode].contains(keycode)
        }
    }
    private static let noSettings = NoSettings()

    // MARK: - Lifecycle

    func start() {
        guard eventTap == nil else { return }

        let trusted = AXIsProcessTrusted()
        print("[LayoutSwitcher] Accessibility trusted: \(trusted)")
        if !trusted {
            print("[LayoutSwitcher] ERROR: Not trusted. Grant Accessibility permission and restart.")
            return
        }

        if let settings = settings {
            // Asynchronous on purpose: with the user's 600k-word custom files this was
            // ~400ms of blocked main thread at every launch. The bundled lists are already
            // in place from DictionaryManager.init, so the first corrections work on those
            // while the custom words arrive a moment later.
            DictionaryManager.shared.rebuildAsync(
                customEnglishWords: settings.customEnglishWords,
                customUkrainianWords: settings.customUkrainianWords,
                customRussianWords: settings.customRussianWords,
                englishPaths: settings.customEnglishDictionaryPaths,
                ukrainianPaths: settings.customUkrainianDictionaryPaths,
                russianPaths: settings.customRussianDictionaryPaths
            )
        }

        engine.seedCaches(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

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
    }

    deinit {
        stop()
    }

    // MARK: - Cache updates (pushed by AppDelegate's system observers)

    func layoutDidChange() {
        engine.layoutDidChange(isCorrecting: isCorrecting)
    }

    func noteSelfInitiatedLayoutSwitch() {
        engine.noteSelfInitiatedLayoutSwitch()
    }

    func frontmostAppDidChange(bundleID: String?) {
        // A queued plan was made against the previous app's caret. No keystroke
        // accompanies an app switch, so without this the backspaces would be delivered to
        // whatever the user just switched to.
        markCorrectionContextDirty()
        engine.frontmostAppDidChange(bundleID: bundleID)
    }

    private func markCorrectionContextDirty() {
        stateLock.lock()
        if _isCorrecting { _correctionContextDirty = true }
        stateLock.unlock()
    }

    // MARK: - Event decoding

    func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            _ = engine.handle(.mouseDown, isCorrecting: isCorrecting)
            return
        }

        guard type == .keyDown else { return }

        // Ignore the keystrokes this app posts itself — see `syntheticEventMarker`.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return
        }

        // A real keystroke while a plan is queued or typing means the caret text no longer
        // matches the snapshot it was built from. The typing checks this once more before
        // its first backspace and aborts.
        markCorrectionContextDirty()

        let flags = event.flags
        let input = InputEvent.keyDown(
            keycode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            shift: flags.contains(.maskShift),
            capsLock: flags.contains(.maskAlphaShift),
            command: flags.contains(.maskCommand),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate)
        )

        switch engine.handle(input, isCorrecting: isCorrecting) {
        case .nothing:
            break
        case .correct(let plan):
            run(plan, kind: .correction(automatic: true))
        case .learnException(let word):
            settings?.addException(word)
        }
    }

    // MARK: - Shortcuts

    func correctLastWordOnDemand() {
        guard let plan = engine.onDemandPlan(isCorrecting: isCorrecting) else {
            debugLog("[LayoutSwitcher] Nothing to convert")
            return
        }
        run(plan, kind: .correction(automatic: false))
    }

    /// The undo key is a toggle on the last word. A fresh correction is reverted; with
    /// nothing to revert, the last word is converted instead — the same key the user reaches
    /// for either way, so it does the thing that makes sense for the text in front of them.
    func undoLastCorrection() {
        if let plan = engine.undoPlan(isCorrecting: isCorrecting) {
            run(plan, kind: .undo)
        } else {
            debugLog("[LayoutSwitcher] Nothing to undo; converting the last word")
            correctLastWordOnDemand()
        }
    }

    // MARK: - Executing a plan

    private enum PlanKind: Equatable {
        /// A correction: records an undo snapshot and counts toward statistics.
        /// `automatic` is false when the user asked for it with a shortcut.
        case correction(automatic: Bool)
        /// Reverses the last correction: clears the snapshot, remembers the word.
        case undo
    }

    private func run(_ plan: CorrectionPlan, kind: PlanKind) {
        // Claim the slot before leaving the main thread, so a second word boundary that
        // arrives while this plan is queued cannot start a second one.
        stateLock.lock()
        _isCorrecting = true
        _correctionContextDirty = false
        stateLock.unlock()

        let delayMs = Self.eraseToRetypeGapMs
        let notify = kind == .correction(automatic: true) && (settings?.showNotifications ?? false)

        correctionQueue.async { [weak self] in
            self?.perform(plan, kind: kind, delayMs: delayMs, notify: notify)
        }
    }

    private func perform(_ plan: CorrectionPlan, kind: PlanKind, delayMs: Int, notify: Bool) {
        let delayUs = UInt32(max(delayMs, 0) * 1000)

        debugLog("[LayoutSwitcher] \(kind) \(plan.from.rawValue) -> \(plan.to.rawValue): "
                 + "'\(plan.originalText)' -> '\(plan.correctText)'")

        // A plan asked for with a shortcut runs while the shortcut's modifiers are still
        // physically down, and the window server folds the hardware modifier state into
        // everything posted: the backspaces went out as ⌃Backspace and the letters as
        // control chords, so the word vanished and nothing replaced it. Wait for the keys
        // to come up. Nothing marks the context dirty in the meantime — the tap does not
        // watch modifier changes — so the plan is still valid afterwards.
        if kind != .correction(automatic: true) {
            waitForModifierRelease()
        }

        // Let the triggering key reach the app, and give a fast typist's next keystroke a
        // moment to arrive and mark the context dirty below.
        usleep(Self.settleBeforeCorrectionUs)

        // Last exit before destructive output: a fast typist may already be into the next
        // word. The backspace count was snapshotted at the boundary, so erasing now would
        // eat the fresh keystrokes. Abort — a missed correction beats mangled text.
        stateLock.lock()
        let dirty = _correctionContextDirty
        if dirty { _isCorrecting = false }
        stateLock.unlock()
        if dirty {
            debugLog("[LayoutSwitcher] Aborted: editing context changed")
            return
        }

        // Erase with an exact number of backspaces. Counted, not selected: Option+Shift+
        // Left lets the text engine find the word start, and it breaks a word on the
        // punctuation that several US-layout keys type for Ukrainian letters — "pfd;lb"
        // for "завжди" selected just "lb". The count is exact because every buffered
        // keystroke produces exactly one character in either layout.
        deleteBackward(characters: plan.deleteCount)

        // The one user-configurable pause, between erasing and retyping — an escape hatch
        // for apps that fall behind on rapid synthetic input. Not needed for ordering.
        usleep(delayUs)

        // Switch input source (TIS APIs must run on the main thread). No pause after it:
        // the retype is unicode events, which carry their characters regardless of layout.
        DispatchQueue.main.sync {
            self.engine.noteSelfInitiatedLayoutSwitch()
            InputSourceManager.switchTo(plan.to)
            self.onSelfInitiatedLayoutSwitch?()
        }

        let typedFully = typeString(plan.correctText)
        if plan.restoreBoundarySpace {
            simulateKey(keycode: KeyMapping.spaceKeycode, flags: [])
        }

        // Publish the result on main, where the engine lives. The undo snapshot is recorded
        // only when every character actually went out: undo erases `correctText.count`
        // characters, and a snapshot longer than what was typed would erase preceding text.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            self._isCorrecting = false
            self.stateLock.unlock()

            switch kind {
            case .correction(let automatic):
                if typedFully { self.engine.correctionApplied(plan, automatic: automatic) }
                self.settings?.recordCorrection()
            case .undo:
                // Remember the corrected form so it is left alone from now on.
                if let word = self.engine.undoApplied() {
                    self.settings?.addException(word)
                }
            }
        }

        if notify {
            showNotification(from: plan.from, to: plan.to, word: plan.correctText)
        }
    }

    // MARK: - Synthetic keystrokes

    /// How long the boundary key is given to land before the first backspace goes out.
    private static let settleBeforeCorrectionUs: UInt32 = 20_000

    /// Pause between erasing the word and retyping it. Not needed for ordering — synthetic
    /// events are delivered in the order posted — but a small margin for apps that fall
    /// behind on rapid input. This used to be a slider (10–200 ms); nobody ever needed more
    /// than the floor, and a slider whose only good position is its minimum is a trap.
    private static let eraseToRetypeGapMs = 10

    /// Pause between synthetic keys. Events posted to the session tap are delivered in the
    /// order posted, so the gap is not for ordering — it is a small margin for apps that
    /// process input on a slow path. It used to be 7ms per key, which made a six-letter
    /// correction take a visible quarter of a second; SwitchFix posts with no gap at all.
    private static let interKeyGapUs: UInt32 = 1_000

    /// Post an event, stamped so the tap callback can tell it apart from real typing.
    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Blocks the correction queue until no modifier key is held, or `modifierReleaseTimeout`
    /// passes — a stuck key must not stall corrections forever.
    private func waitForModifierRelease() {
        let held: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
        let deadline = Date().addingTimeInterval(Self.modifierReleaseTimeout)
        while Date() < deadline,
              !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
            usleep(5_000)
        }
    }

    private static let modifierReleaseTimeout: TimeInterval = 1.0

    /// Press backspace exactly `characters` times.
    private func deleteBackward(characters: Int) {
        guard characters > 0 else { return }
        // A miscomputed count here is destructive, and the buffer is bounded, so treat
        // anything past that bound as a bug and refuse rather than erase the document.
        guard characters <= CorrectionEngine.maxBufferLength + 1 else {
            print("[LayoutSwitcher] Refusing to delete \(characters) characters — count out of range")
            return
        }
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
        post(keyUp)
        usleep(Self.interKeyGapUs)
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
            event.flags = []
            post(event)
            if let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                upEvent.flags = []
                post(upEvent)
            }
            usleep(Self.interKeyGapUs)
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
