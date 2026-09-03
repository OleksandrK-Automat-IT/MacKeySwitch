import Testing
import Foundation
@testable import LayoutSwitcher

// MARK: - Test doubles

final class FakeEnvironment: CorrectionEnvironment {
    var layout: Language? = .english
    var sourceID: String?
    var preferredSources: [Language: String] = [:]
    var deadKeys = InputSourceManager.DeadKeyProfile()
    var isSystemSecureInputEnabled = false
    var field: SecureFieldState = .notSecure
    var now = Date(timeIntervalSince1970: 1_000_000)

    func currentLayout() -> Language? { layout }
    func currentSourceID() -> String? { sourceID }
    func preferredSourceID(for language: Language) -> String? { preferredSources[language] }
    func deadKeyProfile() -> InputSourceManager.DeadKeyProfile { deadKeys }
    func secureFieldState() -> SecureFieldState { field }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

struct TestSettings: CorrectionSettings {
    var isEnabled = true
    var minWordLength = 2
    var scoreThreshold = SettingsModel.Sensitivity.medium.scoreThreshold
    var correctionMode: SettingsModel.CorrectionMode = .automatic
    var excludedApps: Set<String> = []
    var exceptions: Set<String> = []
    func isAppExcluded(bundleID: String) -> Bool { excludedApps.contains(bundleID) }
    func isException(_ word: String) -> Bool { exceptions.contains(word.lowercased()) }
    func isMacKeySwitchHotkey(
        keycode: UInt16, shift: Bool, command: Bool, control: Bool, option: Bool
    ) -> Bool {
        control && shift && !command && !option
            && [UInt16(0x06), UInt16(0x07), KeyMapping.spaceKeycode].contains(keycode)
    }
}

/// A scripted keyboard in front of the engine.
final class Harness {
    let env = FakeEnvironment()
    let engine: CorrectionEngine
    var isCorrecting = false

    static let dictionary = StubDictionary(
        english: ["hello", "three", "wisdom"],
        ukrainian: ["привіт", "завжди", "привітє"]
    )

    init(settings: TestSettings = TestSettings(), dictionary: StubDictionary = Harness.dictionary) {
        engine = CorrectionEngine(environment: env, settings: settings, dictionary: dictionary)
        engine.seedCaches(frontmostBundleID: "com.example.editor")
    }

    @discardableResult
    func key(_ keycode: UInt16, shift: Bool = false, capsLock: Bool = false,
             command: Bool = false, control: Bool = false, option: Bool = false) -> EngineOutcome {
        engine.handle(.keyDown(keycode: keycode, shift: shift, capsLock: capsLock,
                               command: command, control: control, option: option),
                      isCorrecting: isCorrecting)
    }

    /// Types `text` as US-layout keystrokes; returns the outcome of the last one.
    @discardableResult
    func type(_ text: String) -> EngineOutcome {
        var last = EngineOutcome.nothing
        for stroke in keycodes(forTyping: text) {
            last = key(stroke.keycode, shift: stroke.shift, capsLock: stroke.capsLock)
        }
        return last
    }

    @discardableResult func space() -> EngineOutcome { key(KeyMapping.spaceKeycode) }
    @discardableResult func backspace() -> EngineOutcome { key(KeyMapping.backspaceKeycode) }
    @discardableResult func click() -> EngineOutcome { engine.handle(.mouseDown, isCorrecting: isCorrecting) }

    var buffer: String { KeyMapping.reconstruct(keycodes: engine.keyBuffer, language: .english) }

    /// Runs a correction to completion the way the monitor would.
    func correct(_ outcome: EngineOutcome) -> CorrectionPlan? {
        guard case .correct(let plan) = outcome else { return nil }
        engine.correctionApplied(plan)
        return plan
    }
}

// The wrong-layout word every test leans on: "ghbdsn" is "привіт" on a US keyboard.
private let wrongLayoutWord = "ghbdsn"
private let apostropheKey: UInt16 = 0x27   // ' on US, є on Ukrainian

// MARK: - Buffering

@Suite struct EngineBufferingTests {

    @Test func lettersAccumulateAndReconstruct() {
        let h = Harness()
        h.type("hello")
        #expect(h.buffer == "hello")
    }

    @Test func aDigitEmptiesTheBufferButNotTheWord() {
        // Digits print a character the buffer cannot represent, so the backspace count
        // would come up short; the run has to be dropped rather than mis-counted.
        let h = Harness()
        h.type("abc1de")
        #expect(h.buffer == "de")
    }

    @Test func lettersAfterADigitAreNeverCorrectedAsAStandaloneSuffix() {
        let h = Harness()
        h.type("foo1" + wrongLayoutWord)
        #expect(h.space() == .nothing)
    }

    @Test func aSpaceEndsTheWord() {
        let h = Harness()
        h.type("hello"); h.space()
        #expect(h.buffer.isEmpty)
    }

    @Test func theBufferIsCappedAtSixtyFour() {
        let h = Harness()
        h.type(String(repeating: "a", count: CorrectionEngine.maxBufferLength))
        #expect(h.buffer.count == CorrectionEngine.maxBufferLength)
        h.type("a")
        #expect(h.buffer.isEmpty, "the 65th letter resets — something structural is being typed")
    }

    @Test func backspaceShrinksTheBuffer() {
        let h = Harness()
        h.type("hello"); h.backspace(); h.backspace()
        #expect(h.buffer == "hel")
    }

    @Test func aChordEmptiesTheBuffer() {
        let h = Harness()
        h.type("hel"); h.key(0x06, command: true)
        #expect(h.buffer.isEmpty)
    }

    @Test func aClickEmptiesTheBuffer() {
        let h = Harness()
        h.type("hel"); h.click()
        #expect(h.buffer.isEmpty)
    }

    @Test func nothingIsBufferedWhileDisabled() {
        var s = TestSettings(); s.isEnabled = false
        let h = Harness(settings: s)
        h.type("hello")
        #expect(h.buffer.isEmpty)
    }

    @Test func nothingIsBufferedInAnExcludedApp() {
        var s = TestSettings(); s.excludedApps = ["com.example.editor"]
        let h = Harness(settings: s)
        h.type("hello")
        #expect(h.buffer.isEmpty)
    }

    @Test func nothingIsBufferedUnderSecureInput() {
        let h = Harness()
        h.env.isSystemSecureInputEnabled = true
        h.type("hello")
        #expect(h.buffer.isEmpty)
    }

    @Test func nothingIsBufferedOnAnUnhandledLayout() {
        let h = Harness()
        h.env.layout = nil
        h.engine.layoutDidChange(isCorrecting: false)
        h.type("hello")
        #expect(h.buffer.isEmpty)
    }
}

// MARK: - Automatic correction

@Suite struct EngineCorrectionTests {

    @Test func aWrongLayoutWordIsCorrectedOnSpace() {
        let h = Harness()
        h.type(wrongLayoutWord)
        let outcome = h.space()
        #expect(outcome == .correct(CorrectionPlan(
            originalText: "ghbdsn", correctText: "привіт",
            from: .english, to: .ukrainian,
            deleteCount: 7, restoreBoundarySpace: true)))
    }

    @Test func legacyUkrainianGeometryCorrectsIntoUkrainian() {
        let h = Harness()
        h.env.sourceID = "com.apple.keylayout.US"
        h.env.preferredSources[.ukrainian] = KeyMapping.legacyUkrainianSourceID
        h.engine.seedCaches(frontmostBundleID: "com.example.editor")

        // Physical keys for "привіт" on Apple's legacy Ukrainian layout.
        h.type("ghsdbn")
        guard case .correct(let plan) = h.space() else {
            Issue.record("standard Ukrainian target geometry was not corrected")
            return
        }
        #expect(plan.originalText == "ghsdbn")
        #expect(plan.correctText == "привіт")
    }

    @Test func legacyUkrainianGeometryCorrectsBackToEnglish() {
        let h = Harness()
        h.env.layout = .ukrainian
        h.env.sourceID = KeyMapping.legacyUkrainianSourceID
        h.env.preferredSources[.english] = "com.apple.keylayout.US"
        h.engine.seedCaches(frontmostBundleID: "com.example.editor")

        h.type("wisdom")
        guard case .correct(let plan) = h.space() else {
            Issue.record("standard Ukrainian source geometry was not corrected")
            return
        }
        #expect(plan.originalText == "цшивщь")
        #expect(plan.correctText == "wisdom")
    }

    @Test func aRealWordIsLeftAlone() {
        let h = Harness()
        h.type("hello")
        #expect(h.space() == .nothing)
    }

    @Test func tooShortAWordIsLeftAlone() {
        var s = TestSettings(); s.minWordLength = 7
        let h = Harness(settings: s)
        h.type(wrongLayoutWord)
        #expect(h.space() == .nothing)
    }

    @Test func nothingIsCorrectedWhileACorrectionIsAlreadyTyping() {
        let h = Harness()
        h.type(wrongLayoutWord)
        h.isCorrecting = true
        #expect(h.space() == .nothing)
    }

    @Test func aPasswordShapedRunIsLeftAlone() {
        // "Ab1" is not buffered past the digit, but the heuristic saw mixed case plus a
        // digit across the whole run — and that run is still going when "ghbdsn" follows.
        let h = Harness()
        h.type("Ab1" + wrongLayoutWord)
        #expect(h.space() == .nothing)
    }

    @Test func aPasswordFieldIsLeftAlone() {
        let h = Harness()
        h.env.field = .secure
        h.type(wrongLayoutWord)
        #expect(h.space() == .nothing)
    }

    @Test func theSecureFieldQueryOnlyRunsForAWordAboutToBeCorrected() {
        // The accessibility round trip is the one expensive guard, so it must not be paid
        // for words that fail every other check. Observable here: a secure field does not
        // prevent a *real* word from being left alone for the usual reason.
        let h = Harness()
        h.env.field = .secure
        h.type("hello")
        #expect(h.space() == .nothing)
    }

    @Test func anExceptionIsLeftAlone() {
        var s = TestSettings(); s.exceptions = ["ghbdsn"]
        let h = Harness(settings: s)
        h.type(wrongLayoutWord)
        #expect(h.space() == .nothing)
    }

    @Test func aBareDomainIsLeftAlone() {
        let h = Harness(dictionary: StubDictionary(english: [], ukrainian: ["щлюгф"]))
        h.type("ok.ua")   // every key here is a Ukrainian letter: "щлюгф"
        #expect(h.space() == .nothing)
    }

    @Test func returnEndsAWordWithoutCorrectingIt() {
        let h = Harness()
        h.type(wrongLayoutWord)
        #expect(h.key(0x24) == .nothing)
        #expect(h.buffer.isEmpty)
    }

    @Test func hotkeyOnlyModeNeverCorrectsUnasked() {
        var s = TestSettings(); s.correctionMode = .hotkeyOnly
        let h = Harness(settings: s)
        h.type(wrongLayoutWord)
        #expect(h.space() == .nothing)
        // ...but the word is still there for the shortcut.
        #expect(h.engine.onDemandPlan(isCorrecting: false)?.correctText == "привіт")
    }
}

// MARK: - Layout attribution

@Suite struct EngineLayoutTests {

    @Test func aThirdLayoutStartedBeforeItsNotificationIsNotBuffered() {
        // Regression: the cache said English, the system said Russian, and the word was
        // reconstructed as English gibberish, matched Ukrainian, and rewritten in place.
        let h = Harness()
        h.env.layout = nil          // system already on a third layout
        h.type(wrongLayoutWord)     // cache still says English
        #expect(h.buffer.isEmpty)
        #expect(h.space() == .nothing)
    }

    @Test func aLayoutChangeUnderTheWordAbortsTheCorrection() {
        let h = Harness()
        h.type("ghb")
        h.env.layout = .ukrainian   // switched mid-word, notification not yet delivered
        h.type("dsn")
        #expect(h.space() == .nothing)
    }

    @Test func aManualSwitchSuppressesTheNextWordOnly() {
        let h = Harness()
        h.engine.layoutDidChange(isCorrecting: false)
        h.type(wrongLayoutWord)
        #expect(h.space() == .nothing, "first word after a manual switch is protected")
        h.type(wrongLayoutWord)
        #expect(h.correct(h.space()) != nil, "the one after it is not")
    }

    @Test func aBareSpaceDoesNotConsumeTheManualSwitchProtection() {
        let h = Harness()
        h.engine.layoutDidChange(isCorrecting: false)
        h.space()
        h.type(wrongLayoutWord)
        #expect(h.space() == .nothing)
    }

    @Test func theProtectionExpires() {
        let h = Harness()
        h.engine.layoutDidChange(isCorrecting: false)
        h.env.advance(CorrectionEngine.manualSwitchWindow + 1)
        h.type(wrongLayoutWord)
        #expect(h.correct(h.space()) != nil)
    }

    @Test func theAppsOwnSwitchDoesNotSuppressAnything() {
        let h = Harness()
        h.engine.noteSelfInitiatedLayoutSwitch()
        h.engine.layoutDidChange(isCorrecting: false)
        h.type(wrongLayoutWord)
        #expect(h.correct(h.space()) != nil)
    }

    @Test func aSwitchDuringACorrectionIsTheAppsOwn() {
        let h = Harness()
        h.engine.layoutDidChange(isCorrecting: true)
        h.type(wrongLayoutWord)
        #expect(h.correct(h.space()) != nil)
    }
}

// MARK: - Dead keys

@Suite struct EngineDeadKeyTests {

    private func harnessWithDeadApostrophe(resolvable: Bool) -> Harness {
        let h = Harness()
        h.env.deadKeys.dead = [apostropheKey]
        if resolvable { h.env.deadKeys.resolvedByBoundary = [apostropheKey] }
        h.engine.layoutDidChange(isCorrecting: false)
        h.env.advance(CorrectionEngine.manualSwitchWindow + 1)
        return h
    }

    @Test func aDeadKeyMidWordDropsTheRun() {
        let h = harnessWithDeadApostrophe(resolvable: true)
        h.type("ab'c")
        #expect(h.buffer.isEmpty)
    }

    @Test func aDeadKeyEndingTheWordIsCorrectedWithoutTheSpace() {
        // The boundary space was spent resolving the dead key: no space reached the
        // screen, so the count must not include one and none is typed back.
        let h = harnessWithDeadApostrophe(resolvable: true)
        h.type(wrongLayoutWord + "'")
        let plan = h.correct(h.space())
        #expect(plan?.correctText == "привітє")
        #expect(plan?.deleteCount == 7)
        #expect(plan?.restoreBoundarySpace == false)
    }

    @Test func anUnresolvableDeadKeyDropsTheRun() {
        let h = harnessWithDeadApostrophe(resolvable: false)
        h.type(wrongLayoutWord + "'")
        #expect(h.buffer.isEmpty)
    }

    @Test func backspacingAPendingDeadKeyDropsTheRun() {
        let h = harnessWithDeadApostrophe(resolvable: true)
        h.type("ab'"); h.backspace()
        #expect(h.buffer.isEmpty)
    }

    @Test func onDemandRefusesAPendingDeadKey() {
        // The buffer is one character longer than the screen; the count would eat the
        // character before the word.
        let h = harnessWithDeadApostrophe(resolvable: true)
        h.type(wrongLayoutWord + "'")
        #expect(h.engine.onDemandPlan(isCorrecting: false) == nil)
    }
}

// MARK: - On demand

@Suite struct EngineOnDemandTests {

    @Test func midWordThereIsNoSpaceToEraseButOneIsTypedAfter() {
        let h = Harness()
        h.type(wrongLayoutWord)
        let plan = h.engine.onDemandPlan(isCorrecting: false)
        #expect(plan == CorrectionPlan(
            originalText: "ghbdsn", correctText: "привіт",
            from: .english, to: .ukrainian,
            deleteCount: 6, restoreBoundarySpace: true))
    }

    @Test func afterTheSpaceItIsErasedAndPutBack() {
        let h = Harness(dictionary: StubDictionary())   // nothing in any dictionary
        h.type(wrongLayoutWord); h.space()
        let plan = h.engine.onDemandPlan(isCorrecting: false)
        #expect(plan?.deleteCount == 7)
        #expect(plan?.restoreBoundarySpace == true)
        #expect(plan?.correctText == "привіт")
    }

    @Test func itSkipsTheConfidenceScoreEntirely() {
        // Nothing here is in any dictionary; the automatic pass declines, the shortcut
        // converts anyway. That is the point of the shortcut.
        let h = Harness(dictionary: StubDictionary())
        h.type("qwe")
        #expect(h.space() == .nothing)
        #expect(h.engine.onDemandPlan(isCorrecting: false)?.correctText == "йцу")
    }

    @Test func theFinishedWordSurvivesTheShortcutChordItself() {
        let h = Harness(dictionary: StubDictionary())
        h.type(wrongLayoutWord); h.space()
        h.key(KeyMapping.spaceKeycode, shift: true, control: true)   // ⌃⇧Space, as the tap sees it
        #expect(h.engine.onDemandPlan(isCorrecting: false) != nil)
    }

    @Test func aWordStillBeingTypedSurvivesTheChordWithoutABoundary() {
        // ⌃Z straight after the word, no space yet: the shortcut must still find it, and
        // the plan must not erase a space that was never typed.
        let h = Harness(dictionary: StubDictionary())
        h.type(wrongLayoutWord)
        _ = h.key(0x06, shift: true, control: true)
        let plan = h.engine.onDemandPlan(isCorrecting: false)
        #expect(plan?.correctText == "привіт")
        #expect(plan?.deleteCount == 6, "no space was typed, so none is erased")
        #expect(plan?.restoreBoundarySpace == true, "the conversion finishes the word")
    }

    @Test func anEditingChordInvalidatesTheFinishedWord() {
        let h = Harness(dictionary: StubDictionary())
        h.type(wrongLayoutWord); h.space()
        h.key(0x7B, command: true) // Command-Left moves the caret
        #expect(h.engine.onDemandPlan(isCorrecting: false) == nil)
    }

    @Test func aChordAfterAPendingDeadKeyLeavesNothingToConvert() {
        let h = Harness(dictionary: StubDictionary())
        h.env.deadKeys.dead = [apostropheKey]
        h.engine.layoutDidChange(isCorrecting: false)
        h.env.advance(CorrectionEngine.manualSwitchWindow + 1)
        h.type(wrongLayoutWord)
        _ = h.key(apostropheKey)         // dead key: nothing printed yet
        _ = h.key(0x06, control: true)
        #expect(h.engine.onDemandPlan(isCorrecting: false) == nil)
    }

    @Test func theFinishedWordExpires() {
        let h = Harness(dictionary: StubDictionary())
        h.type(wrongLayoutWord); h.space()
        h.env.advance(CorrectionEngine.completedWordLifetime + 1)
        #expect(h.engine.onDemandPlan(isCorrecting: false) == nil)
    }

    @Test func aWordTheAppJustCorrectedIsNotACandidate() {
        let h = Harness()
        h.type(wrongLayoutWord)
        #expect(h.correct(h.space()) != nil)
        #expect(h.engine.onDemandPlan(isCorrecting: false) == nil, "undo is the tool for that")
    }

    @Test func nothingHappensWithNothingToActOn() {
        let h = Harness()
        #expect(h.engine.onDemandPlan(isCorrecting: false) == nil)
    }

    @Test func itWaitsForACorrectionInProgress() {
        let h = Harness()
        h.type(wrongLayoutWord)
        #expect(h.engine.onDemandPlan(isCorrecting: true) == nil)
    }

    @Test func itNeverTypesIntoAPasswordField() {
        let h = Harness()
        h.env.field = .secure
        h.type(wrongLayoutWord)
        #expect(h.engine.onDemandPlan(isCorrecting: false) == nil)
    }
}

// MARK: - Undo and rejection

@Suite struct EngineUndoTests {

    private func corrected() -> (Harness, CorrectionPlan) {
        let h = Harness()
        h.type(wrongLayoutWord)
        return (h, h.correct(h.space())!)
    }

    @Test func undoReversesTheCorrectionExactly() {
        let (h, _) = corrected()
        #expect(h.engine.undoPlan(isCorrecting: false) == CorrectionPlan(
            originalText: "привіт", correctText: "ghbdsn",
            from: .ukrainian, to: .english,
            deleteCount: 7, restoreBoundarySpace: true))
    }

    @Test func undoAccountsForAMissingBoundarySpace() {
        // A correction that wrote no trailing space — the automatic pass mid-word.
        let h = Harness(dictionary: StubDictionary())
        h.engine.correctionApplied(CorrectionPlan(
            originalText: "ghbdsn", correctText: "привіт",
            from: .english, to: .ukrainian,
            deleteCount: 6, restoreBoundarySpace: false
        ))
        #expect(h.engine.undoPlan(isCorrecting: false)?.deleteCount == 6)
        #expect(h.engine.undoPlan(isCorrecting: false)?.restoreBoundarySpace == false)
    }

    @Test func undoExpires() {
        let (h, _) = corrected()
        h.env.advance(CorrectionEngine.undoWindow + 1)
        #expect(h.engine.undoPlan(isCorrecting: false) == nil)
    }

    @Test func undoWaitsForACorrectionInProgress() {
        let (h, _) = corrected()
        #expect(h.engine.undoPlan(isCorrecting: true) == nil)
    }

    @Test func typingForfeitsUndo() {
        let (h, _) = corrected()
        h.type("a")
        #expect(h.engine.undoPlan(isCorrecting: false) == nil)
    }

    @Test func clickingForfeitsUndo() {
        let (h, _) = corrected()
        h.click()
        #expect(h.engine.undoPlan(isCorrecting: false) == nil)
    }

    @Test func switchingAppsForfeitsUndo() {
        let (h, _) = corrected()
        h.engine.frontmostAppDidChange(bundleID: "com.example.other")
        #expect(h.engine.undoPlan(isCorrecting: false) == nil)
    }

    @Test func undoAppliedHandsBackTheWordToRememberAndClears() {
        let (h, _) = corrected()
        #expect(h.engine.undoApplied() == "привіт")
        #expect(h.engine.undoPlan(isCorrecting: false) == nil)
        #expect(h.engine.undoApplied() == nil)
    }

    @Test func undoingAManualConversionTeachesNothing() {
        // The user asked for the conversion and then took it back; the word is not a
        // mistake the app made, so it must not become an exception.
        let h = Harness(dictionary: StubDictionary())
        h.type(wrongLayoutWord)
        h.engine.correctionApplied(h.engine.onDemandPlan(isCorrecting: false)!, automatic: false)
        #expect(h.engine.undoPlan(isCorrecting: false) != nil)
        #expect(h.engine.undoApplied() == nil)
    }

    @Test func backspacingOverTheWholeCorrectionLearnsIt() {
        // Six letters plus the space: the seventh backspace is the one that means "no".
        let (h, _) = corrected()
        for _ in 0..<6 { #expect(h.backspace() == .nothing) }
        #expect(h.backspace() == .learnException("привіт"))
        #expect(h.backspace() == .nothing, "learned once, not on every further key")
    }

    @Test func backspacingWhenNoSpaceWasTypedLearnsOneKeyEarlier() {
        let h = Harness(dictionary: StubDictionary())
        h.engine.correctionApplied(CorrectionPlan(
            originalText: "ghbdsn", correctText: "привіт",
            from: .english, to: .ukrainian,
            deleteCount: 6, restoreBoundarySpace: false
        ))
        for _ in 0..<5 { #expect(h.backspace() == .nothing) }
        #expect(h.backspace() == .learnException("привіт"))
    }

    @Test func aLateBackspaceIsJustABackspace() {
        let (h, _) = corrected()
        h.env.advance(CorrectionEngine.rejectionWindow + 1)
        for _ in 0..<7 { #expect(h.backspace() == .nothing) }
    }
}
