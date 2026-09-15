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
/// clipboard: it is one synchronous call, and nothing here ever touches the pasteboard.
/// `AXError.success` on its own is not proof of anything, though — a real app, live-tested,
/// reported success on every call while the on-screen text never changed at all, some AX
/// bridges (web content in particular) accept the write and silently drop it — so the
/// write is followed by a read-back check against the exact expected result.
///
/// Most browsers and editors do not support the write (nor do they publish `AXSelectedText`
/// or `AXValue` for reading, which is why the read side falls back to ⌘C too), so the
/// fallback for both directions is ⌘C/⌘V. The write-back for ⌘V restores the original
/// clipboard after a single fixed, generous delay rather than trying to detect when the
/// paste completed: a promised `NSPasteboardItem` was tried and measured live to fire
/// within milliseconds of being written — a passive reader of the general pasteboard
/// (Universal Clipboard, a clipboard-history utility) rather than the target app actually
/// processing the paste — so there is no signal here to trust either way.
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
        /// An Accessibility write reported success but the read-back did not match the
        /// expected result. Trying the clipboard next would risk a second, conflicting
        /// write landing on top of whatever the first one actually did.
        case replacementUnconfirmed
    }

    /// How long to wait for the shortcut's own modifier keys to come back up.
    private static let modifierReleaseTimeout: TimeInterval = 1.0

    /// How long to give the frontmost app to answer a copy.
    private static let copyTimeout: TimeInterval = 0.4

    /// How long to wait before restoring the original clipboard after a ⌘V paste. There is
    /// no reliable signal for "the target app has read this" on the general pasteboard —
    /// see the long comment at the call site — so this is a single fixed, deliberately
    /// generous guess rather than an attempt to detect completion. Guessing short is the
    /// original bug: the old clipboard landing in the document in place of the conversion.
    /// Guessing long only delays how soon the user's own clipboard is themselves again.
    private static let clipboardRestoreDelay: TimeInterval = 2.0

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

            readSelection(context: originalContext, pasteboard: pasteboard) { selection in
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
                let converted = LayoutTransliterator.convert(
                    selection, from: source, to: target,
                    sourceID: InputSourceManager.preferredSourceID(for: source),
                    targetID: InputSourceManager.preferredSourceID(for: target)
                )
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
                // A write that is not a clean rejection but visibly did not touch the
                // field either — the selection still reads back as exactly the original
                // text — is as good as never having been attempted. Live-tested: a bridge
                // returned a non-rejection AXError while leaving the field completely
                // untouched, and treating that as merely "uncertain" refused the clipboard
                // fallback for a write that provably never happened.
                func unchanged() -> Bool {
                    guard let element = originalContext.focusedElement else { return false }
                    return stringAttribute(element, kAXSelectedTextAttribute) == selection
                }
                var lastWriteStatus: AXError?
                let replacement = originalContext.focusedElement.map {
                    Self.replaceSelectionViaAccessibility(
                        $0, with: converted, verified: verified, unchanged: unchanged,
                        reportedStatus: { lastWriteStatus = $0 })
                } ?? .rejected
                switch replacement {
                case .applied:
                    guard selectionOperation.canContinue,
                          contextMatches(originalContext, checkRange: false) else {
                        return fail(.contextChanged)
                    }
                    restore(saved, to: pasteboard)
                    InputSourceManager.switchTo(target)
                    debugLog("[LayoutSwitcher] selection converted \(source.rawValue) -> "
                             + "\(target.rawValue) via Accessibility, \(selection.count) chars")
                    complete(.success(Conversion(text: converted, language: target)))
                    return
                case .uncertain:
                    // The write may or may not have actually landed; a second attempt
                    // through the clipboard could double it up or collide with it. Stop.
                    debugLog("[LayoutSwitcher] selection AX write uncertain: "
                             + "status=\(lastWriteStatus.map { String($0.rawValue) } ?? "nil") "
                             + "verified=\(verified()) currentSelectedText="
                             + "\(originalContext.focusedElement.map { String(describing: stringAttribute($0, kAXSelectedTextAttribute)) } ?? "nil")")
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

                // A promised NSPasteboardItem was tried here and measured live: its data
                // provider fired 57ms after the write, on the general pasteboard, on a
                // machine with no target app anywhere near ready to have processed a
                // synthetic ⌘V yet. The general pasteboard has readers this app never
                // posted a paste to — Universal Clipboard/Handoff, any clipboard-history
                // utility — and either can fulfil a promise within milliseconds of the
                // write. There is no signal available here that distinguishes "the target
                // app read this" from "something else touched the pasteboard", so this
                // does not try to detect completion at all: it writes plainly, posts the
                // paste, and waits a single fixed, deliberately generous delay before ever
                // restoring the original clipboard behind it.
                pasteboard.clearContents()
                pasteboard.setString(converted, forType: .string)
                let ourChangeCount = pasteboard.changeCount

                post(keyCode: pasteKeyCode)
                InputSourceManager.switchTo(target)

                DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
                    // Only put the old contents back if nothing newer arrived: a write by
                    // anything else in the meantime is newer than ours and must survive.
                    if pasteboard.changeCount == ourChangeCount {
                        restore(saved, to: pasteboard)
                    }
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
    /// `AXSelectedText`/`AXValue` are optional and a great many apps — browsers, anything
    /// Electron, most editors with a custom text engine — do not publish either. Copy works
    /// wherever ⌘C works, at the cost of borrowing the pasteboard (restored by the caller).
    private static func readSelection(
        context: EditingContext, pasteboard: NSPasteboard,
        completion: @escaping (String?) -> Void
    ) {
        if let element = context.focusedElement {
            let viaAccessibility = selectionText(
                selectedText: stringAttribute(element, kAXSelectedTextAttribute),
                value: stringAttribute(element, kAXValueAttribute), range: context.selectedRange
            )
            if let viaAccessibility, !viaAccessibility.isEmpty {
                completion(viaAccessibility)
                return
            }
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

    /// The text a focused element's own attributes describe, or nil when they do not agree
    /// with each other or do not describe a real selection at all.
    ///
    /// `AXValue` + `AXSelectedTextRange` is preferred over `AXSelectedText` alone where
    /// both are available: an app that publishes a stale or approximate `AXSelectedText`
    /// would otherwise convert the wrong characters, and there is no way to tell from
    /// `AXSelectedText` on its own that it happened.
    static func selectionText(selectedText: String?, value: String?, range: CFRange?) -> String? {
        if let range {
            guard range.location >= 0, range.length > 0 else { return nil }
            if let value {
                let text = value as NSString
                guard range.location <= text.length, range.length <= text.length - range.location
                else { return nil }
                let extracted = text.substring(with: NSRange(location: range.location, length: range.length))
                // Inconsistent AX attributes mean the snapshot is no longer trustworthy.
                if let selectedText, selectedText != extracted { return nil }
                return extracted
            }
        }
        guard let selectedText, !selectedText.isEmpty else { return nil }
        return selectedText
    }

    /// Only an explicitly rejected write permits a second replacement mechanism.
    enum ReplacementResult: Equatable { case applied, rejected, uncertain }

    static func replacementResult(
        write: () -> AXError, verified: () -> Bool, unchanged: () -> Bool = { false }
    ) -> ReplacementResult {
        switch write() {
        case .attributeUnsupported, .notImplemented: return .rejected
        case .success: return verified() ? .applied : (unchanged() ? .rejected : .uncertain)
        default: return unchanged() ? .rejected : .uncertain
        }
    }

    /// The exact string the field should hold after a correct replacement, computed from
    /// its own reported value rather than assumed — so verification can demand an exact
    /// match instead of merely "differs from before", which a corrupted write could too.
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
    /// to the same attributes `readSelection` reads. Never throws or crashes on an element
    /// that refuses — an unsupported attribute is an ordinary `AXError`, not an exception —
    /// so the caller can fall back to the clipboard without knowing which apps support
    /// which direction.
    ///
    /// `AXError.success` on its own is not proof of anything: a real app, live-tested,
    /// reported success on every call while the on-screen text never changed at all — some
    /// AX bridges (web content in particular) accept the write and silently drop it. The
    /// result must match the expected replacement, not merely differ from the original.
    /// An unreadable or unchanged result is uncertain: never follow it with another write.
    static func replaceSelectionViaAccessibility(
        _ element: AXUIElement, with text: String, verified: () -> Bool,
        unchanged: () -> Bool = { false }, reportedStatus: (AXError) -> Void = { _ in }
    ) -> ReplacementResult {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString,
                                                   &settable)
        if status == .attributeUnsupported || status == .notImplemented
            || (status == .success && !settable.boolValue) { return .rejected }
        guard status == .success else { return unchanged() ? .rejected : .uncertain }
        return replacementResult(write: {
            let writeStatus = AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            reportedStatus(writeStatus)
            return writeStatus
        }, verified: verified, unchanged: unchanged)
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
