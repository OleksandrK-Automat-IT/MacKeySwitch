import Testing
import Carbon
@testable import LayoutSwitcher

/// The reconstruction buffer erases the old word with a *counted* run of backspaces, so
/// every buffered keystroke has to have put exactly one character on screen. `KeyMapping`
/// is a static table and cannot know that: which keys are dead is a property of the
/// layout. On US International `'` and `` ` `` type nothing until the next keystroke
/// resolves them — and the resolving keystroke is usually the very space that triggers the
/// correction, so `'` + space types just `'`, no space.
///
/// Counting that key as one character made the correction delete one more character than
/// existed, eating the space in front of the word: typing "куіещкштп gjrfpe'" produced
/// "restoringпоказує" instead of "restoring показує".
/// `@MainActor` because the TIS calls below are main-thread-only, and the testing library
/// runs tests in parallel on background threads.
@Suite @MainActor struct DeadKeyTests {

    /// Resolve a layout by ID the way `InputSourceManager.deadKeycodes` resolves the
    /// current one, so the test exercises the real UCKeyTranslate path.
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

    /// How many characters one key puts on screen for a given layout: 0 for a dead key.
    private func producedCharacterCount(_ data: Data, keycode: UInt16) -> Int {
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = data.withUnsafeBytes { pointer -> OSStatus in
            guard let base = pointer.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keycode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                0, &deadKeyState, characters.count, &length, &characters
            )
        }
        return status == noErr ? length : -1
    }

    @Test func theQuoteKeyIsDeadOnUSInternationalButNotOnUS() throws {
        guard let international = layoutData(forSourceID: "com.apple.keylayout.USInternational-PC"),
              let plainUS = layoutData(forSourceID: "com.apple.keylayout.US") else {
            // Neither layout is installed on this machine; nothing to assert.
            return
        }
        let quote: UInt16 = 0x27
        #expect(producedCharacterCount(international, keycode: quote) == 0,
                "US International's quote key must be dead — that is the whole premise")
        #expect(producedCharacterCount(plainUS, keycode: quote) == 1,
                "plain US types an apostrophe outright, so it stays bufferable")
    }

    /// Whatever the current layout is, every key the monitor buffers must put exactly one
    /// character on screen once the dead ones are excluded. This is the invariant the
    /// backspace count depends on.
    @Test func everyBufferedKeyTypesExactlyOneCharacterOnTheCurrentLayout() throws {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return // an input method rather than a keyboard layout
        }
        let data = unsafeBitCast(dataPtr, to: CFData.self) as Data
        let dead = InputSourceManager.deadKeycodes()

        for keycode in KeyMapping.bufferedKeycodes where !dead.contains(keycode) {
            let produced = producedCharacterCount(data, keycode: keycode)
            let detail = "keycode 0x\(String(keycode, radix: 16)) types \(produced) characters "
                + "but is not reported dead — the backspace count would be wrong"
            #expect(produced == 1 || produced == -1, Comment(rawValue: detail))
        }
    }

    @Test func deadKeysAreReportedForTheCurrentLayout() {
        // Not an assertion about which keys are dead — that depends on the tester's
        // layout — but that the probe runs and returns only keys the monitor buffers.
        let dead = InputSourceManager.deadKeycodes()
        #expect(dead.isSubset(of: KeyMapping.bufferedKeycodes))
    }
}
