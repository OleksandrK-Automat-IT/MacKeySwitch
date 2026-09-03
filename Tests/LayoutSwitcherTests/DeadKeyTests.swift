import Testing
import Carbon
@testable import LayoutSwitcher

/// The reconstruction buffer erases the old word with a *counted* run of backspaces, so
/// every buffered keystroke has to have put exactly one character on screen. `KeyMapping`
/// is a static table and cannot know that: which keys are dead is a property of the
/// layout. On US International `'` and `` ` `` type nothing until the next keystroke
/// resolves them.
///
/// Counting a dead key as one character made the correction delete one character more than
/// existed, eating the space in front of the word: typing "куіещкштп gjrfpe'" produced
/// "restoringпоказує" instead of "restoring показує".
///
/// `@MainActor` because the TIS calls are main-thread-only and the testing library runs
/// tests in parallel on background threads.
@Suite @MainActor struct DeadKeyTests {

    private static let quote: UInt16 = 0x27
    private static let backtick: UInt16 = 0x32
    private static let space: UInt16 = 0x31

    /// Resolve a layout by ID, so the test can examine a layout other than whichever one
    /// the machine running the suite happens to have selected.
    private func layoutData(forSourceID sourceID: String) -> Data? {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue()
                as? [TISInputSource] else { return nil }
        for source in list {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                continue
            }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            guard id == sourceID,
                  let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            return (unsafeBitCast(dataPtr, to: CFData.self) as Data)
        }
        return nil
    }

    /// What a run of keystrokes actually puts on screen, dead-key state carried forward
    /// exactly as the text system carries it.
    private func screenText(_ keycodes: [UInt16], on data: Data) -> String {
        var state: UInt32 = 0
        var text = ""
        for keycode in keycodes {
            text += InputSourceManager.translate(keycode, layoutData: data, deadKeyState: &state) ?? ""
        }
        return text
    }

    // MARK: - The layout facts the whole fix rests on

    @Test func theQuoteKeyIsDeadOnUSInternationalButNotOnPlainUS() throws {
        let international = try #require(layoutData(forSourceID: "com.apple.keylayout.USInternational-PC"))
        let plainUS = try #require(layoutData(forSourceID: "com.apple.keylayout.US"))

        var state: UInt32 = 0
        #expect(InputSourceManager.translate(Self.quote, layoutData: international, deadKeyState: &state) == "",
                "US International's quote key must type nothing — that is the whole premise")

        state = 0
        #expect(InputSourceManager.translate(Self.quote, layoutData: plainUS, deadKeyState: &state) == "'",
                "plain US types an apostrophe outright, so it stays bufferable")
    }

    /// The exact sequence from the bug report: the boundary space is spent resolving the
    /// dead key, so the word is intact on screen but no space follows it.
    @Test func theBoundarySpaceIsConsumedResolvingATrailingDeadKey() throws {
        let data = try #require(layoutData(forSourceID: "com.apple.keylayout.USInternational-PC"))
        // g j r f p e ' — "показує" typed on the wrong layout — then space.
        let word: [UInt16] = [0x05, 0x26, 0x0F, 0x03, 0x23, 0x0E, Self.quote]
        #expect(screenText(word, on: data) == "gjrfpe",
                "the dead key has printed nothing yet")
        #expect(screenText(word + [Self.space], on: data) == "gjrfpe'",
                "the space resolves the quote and does not itself reach the screen")
    }

    @Test func aTrailingDeadKeyIsReportedAsBoundaryResolvable() throws {
        let data = try #require(layoutData(forSourceID: "com.apple.keylayout.USInternational-PC"))
        let profile = InputSourceManager.deadKeyProfile(layoutData: data)

        #expect(profile.dead.contains(Self.quote))
        #expect(profile.dead.contains(Self.backtick))
        // Both resolve into exactly the character KeyMapping predicts, so a word ending in
        // one is still reconstructable — only the trailing space is missing.
        #expect(profile.resolvedByBoundary.contains(Self.quote))
        #expect(profile.resolvedByBoundary.contains(Self.backtick))
    }

    @Test func plainUSHasNoDeadKeysAtAll() throws {
        let data = try #require(layoutData(forSourceID: "com.apple.keylayout.US"))
        let profile = InputSourceManager.deadKeyProfile(layoutData: data)
        #expect(profile.dead.isEmpty)
    }

    @Test func everyRecognisedAppleLayoutMatchesTheStaticCharacterTable() throws {
        let sources = try #require(
            TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]
        )
        for source in sources {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            guard let language = InputSourceManager.language(ofSourceID: id) else { continue }
            let data = unsafeBitCast(dataPtr, to: CFData.self) as Data
            let profile = InputSourceManager.deadKeyProfile(layoutData: data)

            for keycode in KeyMapping.bufferedKeycodes where !profile.dead.contains(keycode) {
                var state: UInt32 = 0
                let actual = InputSourceManager.translate(
                    keycode, layoutData: data, deadKeyState: &state
                )
                let expected = KeyMapping.character(
                    for: Keystroke(keycode: keycode), language: language, sourceID: id
                ).map(String.init)
                #expect(actual == expected,
                        "\(id) key 0x\(String(keycode, radix: 16)) types \(actual ?? "nil"), expected \(expected ?? "nil")")

                state = 0
                let shiftedActual = InputSourceManager.translate(
                    keycode, layoutData: data, deadKeyState: &state,
                    modifierState: UInt32(shiftKey >> 8)
                )
                let shiftedExpected = KeyMapping.character(
                    for: Keystroke(keycode: keycode, shift: true),
                    language: language, sourceID: id
                ).map(String.init)
                #expect(shiftedActual == shiftedExpected,
                        "\(id) shifted key 0x\(String(keycode, radix: 16)) types \(shiftedActual ?? "nil"), expected \(shiftedExpected ?? "nil")")
            }
        }
    }

    @Test func differentlyArrangedLayoutsAreNotClaimedAsSupported() {
        for id in ["com.apple.keylayout.ABC-AZERTY", "com.apple.keylayout.ABC-QWERTZ",
                   "com.apple.keylayout.British-PC"] {
            #expect(InputSourceManager.language(ofSourceID: id) == nil)
        }
    }

    /// Mid-word dead keys stay unreconstructable, which is why the monitor invalidates the
    /// buffer as soon as a second key follows one.
    @Test func aDeadKeyFollowedByALetterCollapsesIntoOneCharacter() throws {
        let data = try #require(layoutData(forSourceID: "com.apple.keylayout.USInternational-PC"))
        // ' + e is one character, not two — the count the buffer would claim is wrong.
        #expect(screenText([Self.quote, 0x0E], on: data) == "é")
        // ' + ' is also one.
        #expect(screenText([Self.quote, Self.quote], on: data) == "'")
    }

    // MARK: - The invariant, on whatever layout the tester is running

    @Test func everyBufferedKeyTypesExactlyOneCharacterOnceDeadOnesAreExcluded() throws {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return // an input method rather than a keyboard layout
        }
        let data = unsafeBitCast(dataPtr, to: CFData.self) as Data
        let profile = InputSourceManager.deadKeyProfile(layoutData: data)

        for keycode in KeyMapping.bufferedKeycodes where !profile.dead.contains(keycode) {
            var state: UInt32 = 0
            let produced = InputSourceManager.translate(keycode, layoutData: data, deadKeyState: &state)
            let detail = "keycode 0x\(String(keycode, radix: 16)) types '\(produced ?? "?")' "
                + "but is not reported dead — the backspace count would be wrong"
            #expect(produced == nil || produced?.count == 1, Comment(rawValue: detail))
        }
    }

    @Test func theProfileOnlyEverReportsKeysTheMonitorBuffers() {
        let profile = InputSourceManager.deadKeyProfile()
        #expect(profile.dead.isSubset(of: KeyMapping.bufferedKeycodes))
        #expect(profile.resolvedByBoundary.isSubset(of: profile.dead))
    }
}
