import ApplicationServices
import Cocoa

/// Converts the current selection to the other layout, on demand.
///
/// The automatic corrector only ever sees one word, and only while it is being typed. This
/// covers what it cannot: text already on screen, pasted from elsewhere, or a whole
/// sentence noticed after the fact. The user selects it and presses the shortcut.
///
/// The work is asynchronous because it has to wait for the shortcut's own modifier keys to
/// come back up. A posted ⌘C or ⌘V carries its own flags, but the physical modifiers are
/// live at the same time, so an app pressed with the chord still held sees ⌃⇧⌘V — which is
/// not Paste, and nothing happens.
///
/// The replacement itself prefers writing straight through Accessibility over the
/// clipboard: a synthetic ⌘V has to be *posted*, and nothing tells this app when the
/// target has actually read the pasteboard as a result. The 0.3s that used to guard the
/// restore was a guess, and on a slow first paste into a freshly focused field it guessed
/// wrong — the restore ran before the app read the converted text, so the paste landed
/// with whatever was on the clipboard *before* this ran. `kAXSelectedTextAttribute` is
/// settable in most native Cocoa text views and sidesteps the whole race: the replacement
/// is one synchronous call, nothing touches the pasteboard. Browsers and most Electron
/// apps do not support the write, and fall through to the clipboard path below exactly as
/// before.
enum SelectionCorrector {

    /// What a successful conversion produced: the text is the word or text the caller can
    /// choose to act on further (e.g. teach into a dictionary); the language is what it was
    /// converted *to*, since the caller has no other way to know which dictionary that is.
    struct Conversion: Equatable {
        let text: String
        let language: Language
    }

    enum Failure: Error {
        case noAccessibility
        case noSelection
        case secureInput
        case contextChanged
        case alreadyRunning
        /// The shortcut's own modifiers never came up. Pasting through them would send
        /// ⌃⇧⌘V, not Paste — the fault the wait exists to prevent.
        case modifiersHeld
        /// The selection is not recognisably one layout, so converting it would corrupt
        /// whichever half is already right.
        case ambiguousLanguage
        case nothingToChange
    }

    /// How long to wait after the pasteboard promise has been fulfilled — the reading
    /// app has been handed the data — before restoring the original clipboard behind it.
    /// Short: by this point the read has actually happened, this is only slack for the
    /// app to finish acting on it.
    private static let providedSettleDelay: TimeInterval = 0.05

    /// How long to wait for the promise to be fulfilled at all before giving up and
    /// restoring anyway. Generous, because the cost of guessing short here is the original
    /// bug — the old clipboard landing in place of the conversion — while guessing long
    /// only delays how soon the user's own clipboard is themselves again.
    private static let providerBackstopTimeout: TimeInterval = 2.0

    /// How long to wait for the shortcut's own modifier keys to come back up.
    private static let modifierReleaseTimeout: TimeInterval = 1.0

    /// How long to give the frontmost app to answer a copy.
    private static let copyTimeout: TimeInterval = 0.4

    /// Main-thread state. A second conversion would overwrite the first one's temporary
    /// pasteboard contents and make both operations target an uncertain selection.
    private static let selectionOperation = CorrectionOperation()

    /// Real typing/clicks observed by KeyboardMonitor invalidate a borrowed selection,
    /// including changes within the same AX text element.
    static func invalidatePendingSelection() {
        selectionOperation.invalidate()
    }

    private struct EditingContext {
        let pid: pid_t
        let focusedElement: AXUIElement?
        let selectedRange: CFRange?
    }

    static func correctSelection(completion: @escaping (Result<Conversion, Failure>) -> Void) {
        guard !selectionOperation.isActive else {
            completion(.failure(.alreadyRunning))
            return
        }
        guard AXIsProcessTrusted() else {
            completion(.failure(.noAccessibility))
            return
        }
        guard SecureInputDetector.current() == .notSecure else {
            completion(.failure(.secureInput))
            return
        }
        guard let originalContext = editingContext() else {
            completion(.failure(.contextChanged))
            return
        }
        selectionOperation.begin()

        func complete(_ result: Result<Conversion, Failure>) {
            selectionOperation.finish(completed: false)
            completion(result)
        }

        whenModifiersAreReleased(onTimeout: { complete(.failure(.modifiersHeld)) }) {
            guard selectionOperation.canContinue, contextMatches(originalContext),
                  SecureInputDetector.current() == .notSecure else {
                complete(.failure(.contextChanged))
                return
            }
            let pasteboard = NSPasteboard.general
            let saved = snapshot(pasteboard)

            readSelection(pasteboard: pasteboard) { selection in
                func fail(_ reason: Failure) {
                    // A user action may have copied newer contents while Copy was pending.
                    if selectionOperation.canContinue { restore(saved, to: pasteboard) }
                    complete(.failure(reason))
                }

                guard let selection = selection, !selection.isEmpty else {
                    return fail(.noSelection)
                }
                // English pairs with the Cyrillic layout the user last worked in.
                let cyrillic = InputSourceManager.preferredCyrillicLanguage() ?? .ukrainian
                guard let source = LayoutTransliterator.detectLanguage(
                    of: selection, preferredCyrillic: cyrillic
                ) else {
                    return fail(.ambiguousLanguage)
                }
                let target = source.correctionTarget(cyrillic: cyrillic)
                let converted = LayoutTransliterator.convert(selection, to: target)
                guard converted != selection else {
                    return fail(.nothingToChange)
                }
                guard selectionOperation.canContinue, contextMatches(originalContext) else {
                    return fail(.contextChanged)
                }
                guard SecureInputDetector.current() == .notSecure else {
                    return fail(.secureInput)
                }
                // Try the direct replacement first — synchronous, and it does not touch
                // the pasteboard, so there is nothing here to race. Reading via Copy above
                // may already have overwritten the pasteboard with the plain selection,
                // so the restore still runs regardless of which path wrote the selection.
                if let element = originalContext.focusedElement,
                   Self.replaceSelectionViaAccessibility(element, with: converted) {
                    restore(saved, to: pasteboard)
                    InputSourceManager.switchTo(target)
                    debugLog("[LayoutSwitcher] selection converted \(source.rawValue) -> "
                             + "\(target.rawValue) via Accessibility, \(selection.count) chars")
                    complete(.success(Conversion(text: converted, language: target)))
                    return
                }

                guard KeyboardMonitor.modifiersAreReleased else {
                    return fail(.modifiersHeld)
                }

                // A promised item, not a plain string: nothing tells this app when a
                // fixed delay is *enough* — 0.3s guessed wrong on a slow first paste and
                // pasted the pre-existing clipboard, which is the bug this replaced. A
                // promise instead calls back the moment something actually asks for the
                // data, which is the closest this app can get to knowing the read really
                // happened, short of the AX write above.
                var ourChangeCount = 0
                var restored = false
                func restoreOnce() {
                    guard !restored else { return }
                    restored = true
                    // Only put the old contents back if nothing newer arrived: a write by
                    // anything else in the meantime is newer than ours and must survive.
                    if pasteboard.changeCount == ourChangeCount {
                        restore(saved, to: pasteboard)
                    }
                }

                let provider = ConvertedTextProvider(text: converted) {
                    // The callback can arrive off-main; pasteboard state and `restored`
                    // are both main-only.
                    DispatchQueue.main.async {
                        // A small settle after the handoff: the callback fires when the
                        // data is handed to the reader, not once it has finished acting
                        // on it, so this is still a guess — just a far smaller one than
                        // guessing before any read has happened at all.
                        DispatchQueue.main.asyncAfter(deadline: .now() + providedSettleDelay) {
                            restoreOnce()
                        }
                    }
                }
                let item = NSPasteboardItem()
                item.setDataProvider(provider, forTypes: [.string])
                pasteboard.clearContents()
                pasteboard.writeObjects([item])
                ourChangeCount = pasteboard.changeCount

                post(keyCode: pasteKeyCode)
                InputSourceManager.switchTo(target)

                // Backstop: if nothing ever asks for the data — the paste never reached
                // the app, or it reads selection state some other way first and gives up
                // — the user's real clipboard must not stay overwritten indefinitely.
                //
                // Capturing `item`/`provider` here is not incidental: neither the
                // pasteboard nor ARC has any reason to keep them alive on their own once
                // this function returns, and the promise can only be fulfilled while they
                // are. This closure is what keeps them retained for as long as the
                // fulfillment window is open.
                DispatchQueue.main.asyncAfter(deadline: .now() + providerBackstopTimeout) {
                    _ = (item, provider)
                    restoreOnce()
                }

                debugLog("[LayoutSwitcher] selection converted \(source.rawValue) -> "
                         + "\(target.rawValue), \(selection.count) chars")
                complete(.success(Conversion(text: converted, language: target)))
            }
        }
    }

    // MARK: - Reading the selection

    /// Accessibility first, then the app's own Copy command.
    ///
    /// `AXSelectedText` is optional and a great many apps — browsers, anything Electron,
    /// most editors with a custom text engine — do not publish it. Asking for it was the
    /// whole implementation at first, and it reported "no selection" for real selections.
    /// Copy works wherever ⌘C works, at the cost of borrowing the pasteboard.
    private static func readSelection(
        pasteboard: NSPasteboard,
        completion: @escaping (String?) -> Void
    ) {
        if let viaAccessibility = accessibilitySelection(), !viaAccessibility.isEmpty {
            completion(viaAccessibility)
            return
        }

        let before = pasteboard.changeCount
        post(keyCode: copyKeyCode)

        // A copy with nothing selected leaves the pasteboard untouched, so an unchanged
        // count is how "no selection" is told apart from "the app was slow".
        let deadline = Date().addingTimeInterval(copyTimeout)
        func poll() {
            if pasteboard.changeCount != before {
                completion(pasteboard.string(forType: .string))
                return
            }
            guard Date() < deadline else {
                completion(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
        }
        poll()
    }

    /// Hands `text` to the pasteboard only once something actually asks for it, and
    /// reports back when that happens — see the promised-item comment in `correctSelection`.
    final class ConvertedTextProvider: NSObject, NSPasteboardItemDataProvider {
        private let text: String
        private let onProvided: () -> Void

        init(text: String, onProvided: @escaping () -> Void) {
            self.text = text
            self.onProvided = onProvided
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            item.setString(text, forType: type)
            onProvided()
        }
    }

    /// Replace the selection in place, for the apps whose focused element accepts a write
    /// to the same attribute `accessibilitySelection()` reads. Never throws or crashes on
    /// an element that refuses — an unsupported attribute is an ordinary `AXError`, not an
    /// exception — so the caller can fall back to the clipboard without knowing which apps
    /// support which direction.
    static func replaceSelectionViaAccessibility(_ element: AXUIElement, with text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            == .success
    }

    /// The selected text of the focused element in the frontmost app, if it publishes one.
    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                application, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (focused as! AXUIElement) // type ID checked immediately above
    }

    private static func editingContext() -> EditingContext? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let element = focusedElement(pid: pid)
        return EditingContext(pid: pid, focusedElement: element,
                              selectedRange: element.flatMap(selectedRange))
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func contextMatches(_ original: EditingContext) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == original.pid else {
            return false
        }
        let current = focusedElement(pid: original.pid)
        switch (original.focusedElement, current) {
        case let (lhs?, rhs?):
            guard CFEqual(lhs, rhs) else { return false }
            if let before = original.selectedRange {
                guard let now = selectedRange(rhs) else { return false }
                return before.location == now.location && before.length == now.length
            }
            return true
        case (nil, nil): return true
        default: return false
        }
    }

    private static func accessibilitySelection() -> String? {
        guard let context = editingContext(), let element = context.focusedElement else {
            return nil
        }

        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextAttribute as CFString, &selectedValue) == .success,
              let selected = selectedValue as? String
        else {
            return nil
        }
        return selected
    }

    // MARK: - Pasteboard

    /// Items read from a pasteboard are invalidated by `clearContents()`, so their data has
    /// to be copied out before anything is cleared.
    struct PasteboardSnapshot {
        let items: [NSPasteboardItem]
    }

    static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        return PasteboardSnapshot(items: items)
    }

    static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !snapshot.items.isEmpty {
            pasteboard.writeObjects(snapshot.items)
        }
    }

    // MARK: - Synthetic keys

    private static let copyKeyCode: CGKeyCode = 0x08  // 'c'
    private static let pasteKeyCode: CGKeyCode = 0x09 // 'v'

    private static func post(keyCode: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Stamped like every other event this app posts, so the keyboard monitor does not
        // mistake it for the user typing and discard the word behind the caret.
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData,
                                       value: KeyboardMonitor.syntheticEventMarker)
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Run `work` once no modifier key is physically down, polling on the main queue.
    ///
    /// Polling rather than blocking: this runs in the hotkey handler on the main thread,
    /// and sleeping there freezes the UI of every app waiting on it. Gives up after
    /// `modifierReleaseTimeout` — and gives up means `onTimeout`, not `work`: running the
    /// paste with the keys still down is the fault this wait exists to prevent.
    private static func whenModifiersAreReleased(
        onTimeout: @escaping () -> Void, _ work: @escaping () -> Void
    ) {
        let deadline = Date().addingTimeInterval(modifierReleaseTimeout)
        let held: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]

        func poll() {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(held).isEmpty {
                work()
            } else if Date() >= deadline {
                onTimeout()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
            }
        }
        poll()
    }
}
