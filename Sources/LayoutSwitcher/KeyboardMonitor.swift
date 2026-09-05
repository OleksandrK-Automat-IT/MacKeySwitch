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

    /// Shared lifecycle of delivery, invalidation and publication.
    private let operation = CorrectionOperation()

    /// True until delivery is abandoned or its result is published on main.
    private var isCorrecting: Bool {
        operation.isActive
    }

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
        SelectionCorrector.invalidatePendingSelection()
        // A queued plan was made against the previous app's caret. No keystroke
        // accompanies an app switch, so without this the backspaces would be delivered to
        // whatever the user just switched to.
        markCorrectionContextDirty()
        engine.frontmostAppDidChange(bundleID: bundleID)
    }

    private func markCorrectionContextDirty() {
        operation.invalidate()
    }

    // MARK: - Event decoding

    func handleEvent(type: CGEventType, event: CGEvent) {
        if event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker,
           type == .keyDown || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            SelectionCorrector.invalidatePendingSelection()
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            // A click moves the caret without a keystroke, exactly as an app switch does,
            // and a queued plan would erase whatever now sits under it. Keystrokes and app
            // switches already invalidated the plan; a click did not — and a shortcut-driven
            // plan waits up to a second for modifiers to come up, plenty of time to click.
            markCorrectionContextDirty()
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
        operation.begin()

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
        if kind != .correction(automatic: true), !waitForModifierRelease() {
            // Still held after the whole wait. Going ahead is precisely the fault this
            // wait exists to prevent — ⌃Backspace instead of Backspace — and a plan not
            // run is a missed correction, which beats a mangled one.
            operation.finish(completed: false)
            debugLog("[LayoutSwitcher] Aborted: modifiers still held")
            return
        }

        // Let the triggering key reach the app, and give a fast typist's next keystroke a
        // moment to arrive and mark the context dirty below.
        usleep(Self.settleBeforeCorrectionUs)

        // First exit before destructive output: a fast typist may already be into the next
        // word. The backspace count was snapshotted at the boundary, so erasing now would
        // eat the fresh keystrokes. Abort — a missed correction beats mangled text.
        if !operation.canContinue {
            operation.finish(completed: false)
            debugLog("[LayoutSwitcher] Aborted: editing context changed")
            return
        }

        // Erase with an exact number of backspaces. Counted, not selected: Option+Shift+
        // Left lets the text engine find the word start, and it breaks a word on the
        // punctuation that several US-layout keys type for Ukrainian letters — "pfd;lb"
        // for "завжди" selected just "lb". The count is exact because every buffered
        // keystroke produces exactly one character in either layout.
        let typedFully = CorrectionDelivery.execute(
            deleteCount: plan.deleteCount, text: plan.correctText,
            restoreSpace: plan.restoreBoundarySpace,
            erasePause: { usleep(delayUs) }
        ) { step in
            // Main owns mouse/key/app invalidations. Checking and posting on that same
            // queue prevents a processed invalidation from slipping between the two.
            let sent = DispatchQueue.main.sync {
                guard self.operation.canContinue else { return false }
                guard Self.modifiersAreReleased else {
                    self.operation.invalidate()
                    return false
                }
                switch step {
                case .backspace:
                    return self.simulateKey(keycode: KeyMapping.backspaceKeycode, flags: [])
                case .space:
                    return self.simulateKey(keycode: KeyMapping.spaceKeycode, flags: [])
                case .character(let character):
                    return self.typeCharacter(character)
                case .switchLayout:
                    self.engine.noteSelfInitiatedLayoutSwitch()
                    InputSourceManager.switchTo(plan.to)
                    self.onSelfInitiatedLayoutSwitch?()
                    return true
                }
            }
            if sent { usleep(Self.interKeyGapUs) }
            return sent
        }

        // Publish the result on main, where the engine lives. The undo snapshot is recorded
        // only when every character actually went out: undo erases `correctText.count`
        // characters, and a snapshot longer than what was typed would erase preceding text.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.operation.finish(completed: typedFully) {
                switch kind {
                case .correction(let automatic):
                    self.engine.correctionApplied(plan, automatic: automatic)
                    self.settings?.recordCorrection()
                case .undo:
                    // Teach only a fully delivered undo in the original context.
                    if let word = self.engine.undoApplied() {
                        self.settings?.addException(word)
                    }
                }
                if notify {
                    self.showNotification(from: plan.from, to: plan.to, word: plan.correctText)
                }
            } else {
                // Partial output cannot safely be undone or taught as an exception.
                _ = self.engine.handle(.mouseDown, isCorrecting: false)
                debugLog("[LayoutSwitcher] Delivery interrupted; discarded correction snapshot")
            }
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

    /// Blocks the correction queue until no modifier key is held. Returns false if one is
    /// still down when `modifierReleaseTimeout` passes — a stuck key must not stall
    /// corrections forever, but it must not be typed through either.
    private func waitForModifierRelease() -> Bool {
        let held: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
        let deadline = Date().addingTimeInterval(Self.modifierReleaseTimeout)
        while Date() < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
                return true
            }
            usleep(5_000)
        }
        return CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty
    }

    private static let modifierReleaseTimeout: TimeInterval = 1.0

    static var modifiersAreReleased: Bool {
        let held: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
        return CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty
    }

    private func simulateKey(keycode: UInt16, flags: CGEventFlags) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        post(keyDown)
        post(keyUp)
        return true
    }

    /// Allocate both halves before posting, so allocation failure leaves no held key.
    private func typeCharacter(_ char: Character) -> Bool {
        let str = String(char)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return false }
        let utf16 = Array(str.utf16)
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        event.flags = []
        post(event)
        upEvent.flags = []
        post(upEvent)
        return true
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
