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
/// apps do not support the write and use a clipboard transaction instead. Only verified
/// target text acknowledges that transaction; clipboard observers are not paste receipts.
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
        case replacementUnconfirmed
    }

    /// Bound verification, not clipboard restoration. An unconfirmed paste keeps its
    /// payload on the clipboard so a late Cmd+V cannot pick up the previous contents.
    private static let pasteVerificationTimeout: TimeInterval = 2.0

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
                let borrowedChangeCount = pasteboard.changeCount
                func restoreBorrowedClipboard() {
                    if pasteboard.changeCount == borrowedChangeCount {
                        restore(saved, to: pasteboard)
                    }
                }
                func fail(_ reason: Failure) {
                    // A user action may have copied newer contents while Copy was pending.
                    if selectionOperation.canContinue { restoreBorrowedClipboard() }
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
                let expectedValue = originalContext.focusedElement.flatMap { element in
                    expectedReplacementValue(value: stringAttribute(element, kAXValueAttribute),
                                             range: originalContext.selectedRange,
                                             original: selection, replacement: converted)
                }
                func verified() -> Bool {
                    guard let element = originalContext.focusedElement else { return false }
                    if let expectedValue {
                        return stringAttribute(element, kAXValueAttribute) == expectedValue
                    }
                    return stringAttribute(element, kAXSelectedTextAttribute) == converted
                }
                let replacement = originalContext.focusedElement.map {
                    Self.replaceSelectionViaAccessibility($0, with: converted, verified: verified)
                } ?? .rejected
                switch replacement {
                case .applied:
                    guard selectionOperation.canContinue,
                          contextMatches(originalContext, checkRange: false) else {
                        return fail(.contextChanged)
                    }
                    restoreBorrowedClipboard()
                    InputSourceManager.switchTo(target)
                    debugLog("[LayoutSwitcher] selection converted \(source.rawValue) -> "
                             + "\(target.rawValue) via Accessibility, \(selection.count) chars")
                    complete(.success(Conversion(text: converted, language: target)))
                    return
                case .uncertain:
                    return fail(.replacementUnconfirmed)
                case .rejected:
                    break
                }

                guard selectionOperation.canContinue, contextMatches(originalContext),
                      SecureInputDetector.current() == .notSecure else {
                    return fail(.contextChanged)
                }
                guard KeyboardMonitor.modifiersAreReleased else {
                    return fail(.modifiersHeld)
                }

                // Plain data: a promise can be fulfilled by any clipboard reader and
                // cannot identify the target app. Keep the operation reserved until the
                // target text is verified or the attempt is declared unconfirmed.
                guard let transaction = SelectionPasteTransaction(
                    pasteboard: pasteboard, saved: saved, text: converted
                ) else { return complete(.failure(.replacementUnconfirmed)) }

                post(keyCode: pasteKeyCode)

                // This closure owns the transaction through its terminal state. There
                // are no detached restore timers that could affect a later conversion.
                let deadline = ProcessInfo.processInfo.systemUptime + pasteVerificationTimeout
                func pollPaste() {
                    // A successful replacement changes the selection range itself.
                    let valid = selectionOperation.canContinue
                        && contextMatches(originalContext, checkRange: false)
                        && SecureInputDetector.current() == .notSecure
                    switch transaction.update(
                        valid: valid, verified: valid && verified(),
                        timedOut: ProcessInfo.processInfo.systemUptime >= deadline
                    ) {
                    case .pending:
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { pollPaste() }
                    case .confirmed:
                        InputSourceManager.switchTo(target)
                        complete(.success(Conversion(text: converted, language: target)))
                    case .unconfirmed:
                        complete(.failure(.replacementUnconfirmed))
                    }
                }
                pollPaste()
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

    /// Only an explicitly rejected write permits a second replacement mechanism.
    enum ReplacementResult: Equatable { case applied, rejected, uncertain }

    static func replacementResult(write: () -> AXError, verified: () -> Bool) -> ReplacementResult {
        switch write() {
        case .attributeUnsupported, .notImplemented: return .rejected
        case .success: return verified() ? .applied : .uncertain
        default: return .uncertain
        }
    }

    static func expectedReplacementValue(value: String?, range: CFRange?,
                                         original: String, replacement: String) -> String? {
        guard let value, let range, range.location >= 0, range.length > 0 else { return nil }
        let text = value as NSString
        guard range.location <= text.length, range.length <= text.length - range.location else {
            return nil
        }
        let selected = NSRange(location: range.location, length: range.length)
        guard text.substring(with: selected) == original else { return nil }
        return text.replacingCharacters(in: selected, with: replacement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// Replace the selection in place, for the apps whose focused element accepts a write
    /// to the same attribute `accessibilitySelection()` reads. Never throws or crashes on
    /// an element that refuses — an unsupported attribute is an ordinary `AXError`, not an
    /// exception — so the caller can fall back to the clipboard without knowing which apps
    /// support which direction.
    ///
    /// `AXError.success` on its own is not proof of anything: a real app, live-tested,
    /// reported success on every call while the on-screen text never changed at all — some
    /// AX bridges (web content in particular) accept the write and silently drop it. The
    /// result must match the expected replacement, not merely differ from the original.
    /// An unreadable or unchanged result is uncertain: never follow it with another write.
    static func replaceSelectionViaAccessibility(
        _ element: AXUIElement, with text: String, verified: () -> Bool
    ) -> ReplacementResult {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString,
                                                   &settable)
        if status == .attributeUnsupported || status == .notImplemented
            || (status == .success && !settable.boolValue) { return .rejected }
        guard status == .success else { return .uncertain }
        return replacementResult(write: {
            AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        }, verified: verified)
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

    private static func contextMatches(_ original: EditingContext, checkRange: Bool = true) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == original.pid else {
            return false
        }
        let current = focusedElement(pid: original.pid)
        switch (original.focusedElement, current) {
        case let (lhs?, rhs?):
            guard CFEqual(lhs, rhs) else { return false }
            if checkRange, let before = original.selectedRange {
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
