import Foundation

// MARK: - Inputs

/// A keystroke or click as the engine sees it: a plain value, so a test can make one
/// without a CGEvent. The keyboard monitor decodes CGEvents into these.
enum InputEvent: Equatable {
    case keyDown(keycode: UInt16, shift: Bool = false, capsLock: Bool = false,
                 command: Bool = false, control: Bool = false, option: Bool = false)
    case mouseDown
}

/// What the engine asks the system. Production answers from TIS, accessibility and the
/// clock; tests answer from fields they set.
protocol CorrectionEnvironment {
    /// The layout the system reports, or nil for one the app does not handle.
    func currentLayout() -> Language?
    func deadKeyProfile() -> InputSourceManager.DeadKeyProfile
    var isSystemSecureInputEnabled: Bool { get }
    func secureFieldState() -> SecureFieldState
    var now: Date { get }
}

/// The settings the engine consults. `SettingsModel` conforms; tests use a plain struct.
protocol CorrectionSettings {
    var isEnabled: Bool { get }
    var minWordLength: Int { get }
    var scoreThreshold: Int { get }
    var correctionMode: SettingsModel.CorrectionMode { get }
    func isAppExcluded(bundleID: String) -> Bool
    func isException(_ word: String) -> Bool
}

extension SettingsModel: CorrectionSettings {
    var scoreThreshold: Int { sensitivity.scoreThreshold }
}

// MARK: - Outputs

/// Exactly what to do to the text in front of the caret. Executed by the keyboard monitor
/// with synthetic keystrokes; undo is the same shape run in reverse.
struct CorrectionPlan: Equatable {
    /// What is on screen now, and will be erased.
    let originalText: String
    /// What replaces it.
    let correctText: String
    let from: Language
    let to: Language
    /// Characters to erase: the word, plus the boundary space when one reached the screen.
    let deleteCount: Int
    /// Whether to type a space after the replacement — only when one was erased.
    let restoreBoundarySpace: Bool
}

/// What handling one event asks the monitor to do beyond updating engine state.
enum EngineOutcome: Equatable {
    case nothing
    case correct(CorrectionPlan)
    /// The user backspaced over a correction: remember the word so it is left alone.
    case learnException(String)
}

// MARK: - Engine

/// Every decision the keyboard monitor makes, with none of the machinery.
///
/// This is the buffer of keystrokes behind the caret and the rules for when its contents
/// get rewritten. It runs on the main thread, holds no locks, posts no events and never
/// touches CGEvent, TIS or accessibility directly — all of that is behind
/// `CorrectionEnvironment` — which is what lets `CorrectionEngineTests` drive it with a
/// scripted keyboard. The third-layout bug and the dead-key-count bug both lived in this
/// logic while it was welded to the event tap, where no test could reach them.
final class CorrectionEngine {
    let environment: CorrectionEnvironment
    var settings: CorrectionSettings
    var dictionary: WordSource

    init(environment: CorrectionEnvironment, settings: CorrectionSettings, dictionary: WordSource) {
        self.environment = environment
        self.settings = settings
        self.dictionary = dictionary
    }

    // MARK: State

    /// The contiguous run of reconstructable characters immediately before the caret.
    ///
    /// The correction erases that run with a counted run of backspaces, so the buffer must
    /// never claim more (or fewer) characters than are actually on screen. Anything that
    /// breaks the correspondence — a digit, a '-', an arrow key, a mouse click — empties it
    /// rather than silently desynchronising it. See `invalidateBuffer`.
    private(set) var keyBuffer: [Keystroke] = []

    /// Password shape of the current run of keystrokes, fed digits as well as letters.
    private var passwordHeuristic = PasswordHeuristic()

    /// The word just finished, kept so the on-demand shortcut has something to act on after
    /// the boundary has already emptied the buffer. Only valid while it is still the text
    /// immediately behind the caret, so it dies with the buffer.
    private struct CompletedWord {
        let keystrokes: [Keystroke]
        let layout: Language
        /// Whether the boundary space actually printed — a dead key may have eaten it.
        let boundaryReachedScreen: Bool
        let finishedAt: Date
    }
    private var lastCompletedWord: CompletedWord?

    /// How long a finished word stays eligible for the on-demand shortcut. Matches undo's
    /// window: past it, the odds that the text is still behind the caret are not worth the
    /// cost of being wrong.
    static let completedWordLifetime: TimeInterval = 10.0
    static let undoWindow: TimeInterval = 10.0
    /// Backspaces this long after a correction count as rejecting it.
    static let rejectionWindow: TimeInterval = 5.0
    /// A manual layout switch this recent suppresses the next word's correction.
    static let manualSwitchWindow: TimeInterval = 2.0
    /// The layout-change notification arrives asynchronously and can land after a
    /// correction has finished; within this window it is still read as the app's own.
    static let selfSwitchGrace: TimeInterval = 1.0
    /// Max buffer length — prevents unbounded growth in fields without spaces.
    static let maxBufferLength = 64

    private var wordStartLayout: Language?

    /// The undo snapshot: what the last correction replaced, and what it wrote.
    private struct AppliedCorrection {
        let plan: CorrectionPlan
        let at: Date
    }
    private var lastCorrection: AppliedCorrection?
    private var backspacesSinceCorrection = 0

    private var lastManualSwitchTime: Date?
    /// Set at word-start when a manual switch was recent; skips this word's correction.
    private var skipCurrentWordCorrection = false
    private var lastSelfSwitchTime: Date?

    /// Layout and frontmost app, cached rather than queried per keystroke: both are
    /// cross-process calls, and this runs inside an event tap callback.
    private(set) var cachedLayout: Language?
    private var cachedDeadKeys = InputSourceManager.DeadKeyProfile()
    private(set) var frontmostBundleID: String?

    /// The last buffered key was a dead key, so it has put nothing on screen yet. The
    /// boundary space will resolve it into one character and be consumed doing so.
    private var bufferEndsWithDeadKey = false

    // MARK: Cache updates

    func seedCaches(frontmostBundleID: String?) {
        cachedLayout = environment.currentLayout()
        cachedDeadKeys = environment.deadKeyProfile()
        self.frontmostBundleID = frontmostBundleID
    }

    /// The selected keyboard layout changed. Refreshes the cache and, when the change came
    /// from the user rather than from this app, suppresses the next word's correction.
    func layoutDidChange(isCorrecting: Bool) {
        cachedLayout = environment.currentLayout()
        cachedDeadKeys = environment.deadKeyProfile()

        let selfSwitchedRecently = lastSelfSwitchTime.map {
            environment.now.timeIntervalSince($0) < Self.selfSwitchGrace
        } ?? false
        guard !isCorrecting, !selfSwitchedRecently else { return }

        lastManualSwitchTime = environment.now
        // The run in front of the caret was typed in the previous layout; it can no longer
        // be reconstructed as one word.
        resetBuffer()
    }

    /// Record that this app is about to change the input source, so the notification it
    /// causes is not read as the user switching layout by hand.
    func noteSelfInitiatedLayoutSwitch() {
        lastSelfSwitchTime = environment.now
    }

    /// The frontmost application changed. The caret is now somewhere else entirely, and
    /// the undo snapshot describes text in the previous app.
    func frontmostAppDidChange(bundleID: String?) {
        frontmostBundleID = bundleID
        resetBuffer()
        clearCorrectionSnapshot()
    }

    // MARK: Events

    /// `isCorrecting` is the monitor's cross-thread flag: true while a plan is being typed.
    func handle(_ event: InputEvent, isCorrecting: Bool) -> EngineOutcome {
        switch event {
        case .mouseDown:
            // A click can put the caret anywhere. Whatever the buffer described is no
            // longer the text immediately behind it — and neither is the undo snapshot.
            resetBuffer()
            clearCorrectionSnapshot()
            return .nothing

        case let .keyDown(keycode, shift, capsLock, command, control, option):
            return handleKeyDown(keycode: keycode, shift: shift, capsLock: capsLock,
                                 chord: command || control || option,
                                 isCorrecting: isCorrecting)
        }
    }

    private func handleKeyDown(keycode: UInt16, shift: Bool, capsLock: Bool,
                               chord: Bool, isCorrecting: Bool) -> EngineOutcome {
        guard settings.isEnabled else { return .nothing }

        // Never buffer anything typed into a password field. The system-wide flag is a
        // cheap read; the costlier accessibility query runs once per word, at the boundary.
        if environment.isSystemSecureInputEnabled {
            resetBuffer()
            return .nothing
        }

        if chord {
            // The snapshot of the finished word survives the chord. A chord prints nothing,
            // so that word is still behind the caret — and one of these chords *is* the
            // shortcut asking to correct it. The tap sees the chord before the hotkey
            // fires, so clearing it here made the on-demand correction unable to ever
            // find anything. Staleness is bounded by `completedWordLifetime` instead.
            let finished = lastCompletedWord
            resetBuffer()
            lastCompletedWord = finished
            return .nothing
        }

        if let bundleID = frontmostBundleID, settings.isAppExcluded(bundleID: bundleID) {
            resetBuffer()
            return .nothing
        }

        guard let currentLang = cachedLayout else {
            resetBuffer()
            return .nothing
        }

        if keycode == KeyMapping.backspaceKeycode {
            return handleBackspace()
        }

        // Any non-backspace key clears the undo snapshot. Otherwise the undo shortcut two
        // words later would erase the wrong word and replace it with the earlier one.
        clearCorrectionSnapshot()

        if KeyMapping.wordBoundaryKeycodes.contains(keycode) {
            guard KeyMapping.correctionTriggerKeycodes.contains(keycode) else {
                resetBuffer()
                return .nothing
            }
            // A pending dead key spends this space resolving itself, so no space reaches
            // the screen and the correction must not count one.
            let boundaryReachedScreen = !bufferEndsWithDeadKey
            let finished = CompletedWord(
                keystrokes: keyBuffer,
                layout: wordStartLayout ?? currentLang,
                boundaryReachedScreen: boundaryReachedScreen,
                finishedAt: environment.now
            )
            var plan: CorrectionPlan?
            if settings.correctionMode == .automatic {
                plan = maybeCorrect(currentLanguage: currentLang,
                                    boundaryReachedScreen: boundaryReachedScreen,
                                    isCorrecting: isCorrecting)
            }
            resetBuffer()
            // A word the app is about to correct is not a candidate for correcting again —
            // undo is the tool for that one.
            lastCompletedWord = (plan != nil || finished.keystrokes.isEmpty) ? nil : finished
            return plan.map { .correct($0) } ?? .nothing
        }

        // Fed before the letter-only guard: digits and symbols are not letter keys, and
        // the heuristic could never see them otherwise.
        passwordHeuristic.record(keycode: keycode, isShifted: shift, capsLock: capsLock)

        // Everything that is not a buffered letter key breaks the buffer's correspondence
        // with the screen: digits and '-' print a character that is never buffered, so the
        // backspace count would come up short; arrows and Home/End move the caret. Empty
        // the buffer rather than ignore the key. The password heuristic keeps running —
        // "Ab12cd" is one run of keystrokes even though the digits never buffer.
        guard KeyMapping.isLetterKey(keycode) else {
            invalidateBuffer()
            return .nothing
        }

        // A dead key prints nothing until the next keystroke resolves it, and what the two
        // then produce is not something the static map can predict. Only one case stays
        // reconstructable — the dead key ending the word, resolved by the boundary space
        // into exactly the character the map claims.
        if bufferEndsWithDeadKey {
            invalidateBuffer()
            return .nothing
        }
        if cachedDeadKeys.dead.contains(keycode) {
            guard cachedDeadKeys.resolvedByBoundary.contains(keycode) else {
                invalidateBuffer()
                return .nothing
            }
            bufferEndsWithDeadKey = true
        }

        if keyBuffer.isEmpty {
            // The manual-switch suppression is consumed here — when a letter actually
            // starts a word — not on any first key: a bare space after the switch used to
            // eat the flag and leave the *next* word unprotected.
            if let manualTime = lastManualSwitchTime {
                if environment.now.timeIntervalSince(manualTime) < Self.manualSwitchWindow {
                    skipCurrentWordCorrection = true
                }
                lastManualSwitchTime = nil
            }
            // Confirm the layout with the system instead of trusting the cache. The cache
            // is fed by a notification that arrives late often enough to matter — most
            // reliably right after the app's own switch, which is exactly when the next
            // word begins. A word attributed to the previous layout reconstructs as
            // gibberish, matches the other dictionary, and the "correction" retypes the
            // text already on screen.
            guard let live = confirmedLayout() else {
                // The cache said English or Ukrainian; the system says neither — a third
                // layout whose notification has not landed. Buffering under the stale
                // layout would rewrite text inside a field the app does not handle.
                invalidateBuffer()
                return .nothing
            }
            wordStartLayout = live
        }

        keyBuffer.append(Keystroke(keycode: keycode, shift: shift, capsLock: capsLock))

        if keyBuffer.count > Self.maxBufferLength {
            // Treat as non-word — the user is probably typing something structural.
            resetBuffer()
        }
        return .nothing
    }

    private func handleBackspace() -> EngineOutcome {
        let learned = countBackspaceAgainstLastCorrection()

        // Backspacing over a pending dead key cancels it rather than deleting a character,
        // so the buffer and the screen no longer agree on the count.
        if bufferEndsWithDeadKey {
            invalidateBuffer()
            passwordHeuristic.removeLast()
            return learned.map { .learnException($0) } ?? .nothing
        }

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
        return learned.map { .learnException($0) } ?? .nothing
    }

    /// Enough backspaces to wipe the last correction means the user rejected it. Returns
    /// the corrected word to remember as an exception, once.
    private func countBackspaceAgainstLastCorrection() -> String? {
        guard let last = lastCorrection,
              environment.now.timeIntervalSince(last.at) < Self.rejectionWindow else { return nil }

        backspacesSinceCorrection += 1

        // The correction typed the word *and* (usually) a trailing space, so erasing it
        // takes count + 1 backspaces. Comparing against count alone fired one keystroke
        // early, while a letter was still on screen.
        let erasedLength = last.plan.correctText.count + (last.plan.restoreBoundarySpace ? 1 : 0)
        guard backspacesSinceCorrection >= erasedLength else { return nil }

        let word = last.plan.correctText
        clearCorrectionSnapshot()
        return word
    }

    // MARK: Deciding

    /// Read the live layout, refreshing the cache with it. Once per word.
    private func confirmedLayout() -> Language? {
        let live = environment.currentLayout()
        if live != cachedLayout {
            cachedLayout = live
            cachedDeadKeys = environment.deadKeyProfile()
        }
        return live
    }

    /// Decide whether the just-finished word should be retyped in the other layout.
    private func maybeCorrect(currentLanguage: Language, boundaryReachedScreen: Bool,
                              isCorrecting: Bool) -> CorrectionPlan? {
        if skipCurrentWordCorrection { return nil }

        guard keyBuffer.count >= settings.minWordLength,
              !isCorrecting,
              !passwordHeuristic.looksLikePassword else { return nil }

        let layout = wordStartLayout ?? currentLanguage
        let buffer = keyBuffer

        // If the system disagrees about the layout now, the buffer does not describe what
        // is on screen. Unknown counts as changed: nil is a layout this app cannot read.
        guard let live = confirmedLayout(), live == layout else { return nil }

        let originalText = KeyMapping.reconstruct(keycodes: buffer, language: layout)

        // URLs, emails and identifiers read as ordinary words to the detector — several
        // US-layout punctuation keys are Ukrainian letters, so "ok.ua" buffers like any
        // other word. Rewriting one breaks a link the user is about to use.
        if WordFilter.shouldSkip(originalText) { return nil }

        // Exceptions are keyed on what the user actually typed.
        if settings.isException(originalText) { return nil }

        guard let intended = LanguageDetector.detectIntended(
            keycodes: buffer, currentLayout: layout,
            threshold: settings.scoreThreshold, settings: nil, dictionary: dictionary
        ) else { return nil }

        // The password check is the one expensive guard — an accessibility round trip —
        // so it runs last, only for a word that is actually about to be rewritten.
        guard environment.secureFieldState() == .notSecure else { return nil }

        let correctText = KeyMapping.reconstruct(keycodes: buffer, language: intended)
        return CorrectionPlan(
            originalText: originalText, correctText: correctText,
            from: layout, to: intended,
            deleteCount: originalText.count + (boundaryReachedScreen ? 1 : 0),
            restoreBoundarySpace: boundaryReachedScreen
        )
    }

    /// Convert the last word on demand, whatever the detector thought of it.
    ///
    /// Deliberately skips the confidence score: the score decides whether to act *unasked*,
    /// and here the user has asked. What remains is safety — never a password field, never
    /// a stale snapshot. Acts on the word being typed when there is one, otherwise on the
    /// word just finished.
    func onDemandPlan(isCorrecting: Bool) -> CorrectionPlan? {
        guard !isCorrecting else { return nil }
        guard environment.secureFieldState() == .notSecure else { return nil }

        let keystrokes: [Keystroke]
        let layout: Language
        let boundaryReachedScreen: Bool

        if !keyBuffer.isEmpty {
            // A pending dead key has printed nothing yet, so the buffer is one character
            // longer than the screen and the backspace count would eat the character
            // before the word.
            guard !bufferEndsWithDeadKey else { return nil }
            // Mid-word: no boundary space has been typed yet, so none is behind the caret.
            keystrokes = keyBuffer
            layout = wordStartLayout ?? cachedLayout ?? .english
            boundaryReachedScreen = false
        } else if let finished = lastCompletedWord,
                  environment.now.timeIntervalSince(finished.finishedAt) < Self.completedWordLifetime {
            keystrokes = finished.keystrokes
            layout = finished.layout
            boundaryReachedScreen = finished.boundaryReachedScreen
        } else {
            return nil
        }
        guard !keystrokes.isEmpty else { return nil }

        let target = layout.opposite
        let originalText = KeyMapping.reconstruct(keycodes: keystrokes, language: layout)
        let correctText = KeyMapping.reconstruct(keycodes: keystrokes, language: target)
        guard originalText != correctText else { return nil }

        // The word is being replaced wherever it sits; the buffer no longer describes it.
        resetBuffer()

        return CorrectionPlan(
            originalText: originalText, correctText: correctText,
            from: layout, to: target,
            deleteCount: originalText.count + (boundaryReachedScreen ? 1 : 0),
            restoreBoundarySpace: boundaryReachedScreen
        )
    }

    /// The plan that reverses the last correction, if there is one recent enough.
    func undoPlan(isCorrecting: Bool) -> CorrectionPlan? {
        guard !isCorrecting, let last = lastCorrection,
              environment.now.timeIntervalSince(last.at) < Self.undoWindow,
              !last.plan.correctText.isEmpty else { return nil }
        let p = last.plan
        return CorrectionPlan(
            originalText: p.correctText, correctText: p.originalText,
            from: p.to, to: p.from,
            deleteCount: p.correctText.count + (p.restoreBoundarySpace ? 1 : 0),
            restoreBoundarySpace: p.restoreBoundarySpace
        )
    }

    // MARK: Results

    /// Every character of the plan went out; it can be undone from here.
    func correctionApplied(_ plan: CorrectionPlan) {
        lastCorrection = AppliedCorrection(plan: plan, at: environment.now)
        backspacesSinceCorrection = 0
    }

    /// Undo has run. Returns the word to remember as an exception, so it is left alone.
    func undoApplied() -> String? {
        defer { clearCorrectionSnapshot() }
        return lastCorrection?.plan.correctText
    }

    // MARK: Helpers

    /// Full reset at a word boundary, or when the caret has moved somewhere unknown.
    private func resetBuffer() {
        lastCompletedWord = nil
        keyBuffer.removeAll()
        wordStartLayout = nil
        skipCurrentWordCorrection = false
        bufferEndsWithDeadKey = false
        passwordHeuristic.reset()
    }

    /// Drop the reconstructable run but keep the password heuristic going.
    private func invalidateBuffer() {
        lastCompletedWord = nil
        keyBuffer.removeAll()
        wordStartLayout = nil
        bufferEndsWithDeadKey = false
    }

    private func clearCorrectionSnapshot() {
        lastCorrection = nil
        backspacesSinceCorrection = 0
    }
}

// MARK: - Production environment

/// The real system, for the running app.
struct LiveCorrectionEnvironment: CorrectionEnvironment {
    func currentLayout() -> Language? { InputSourceManager.currentLanguage() }
    func deadKeyProfile() -> InputSourceManager.DeadKeyProfile { InputSourceManager.deadKeyProfile() }
    var isSystemSecureInputEnabled: Bool { SecureInputDetector.isSystemSecureInputEnabled }
    func secureFieldState() -> SecureFieldState { SecureInputDetector.current() }
    var now: Date { Date() }
}
