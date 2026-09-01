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
enum SelectionCorrector {

    enum Failure: Error {
        case noAccessibility
        case noSelection
        /// The selection is not recognisably one layout, so converting it would corrupt
        /// whichever half is already right.
        case ambiguousLanguage
        case nothingToChange
    }

    /// How long to wait before restoring the pasteboard. Long enough for the target app to
    /// have read the paste, short enough that the user is unlikely to copy something else
    /// into the gap.
    private static let pasteboardRestoreDelay: TimeInterval = 0.3

    /// How long to wait for the shortcut's own modifier keys to come back up.
    private static let modifierReleaseTimeout: TimeInterval = 1.0

    /// How long to give the frontmost app to answer a copy.
    private static let copyTimeout: TimeInterval = 0.4

    static func correctSelection(completion: @escaping (Result<String, Failure>) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(.failure(.noAccessibility))
            return
        }

        whenModifiersAreReleased {
            let pasteboard = NSPasteboard.general
            let saved = snapshot(pasteboard)

            readSelection(pasteboard: pasteboard) { selection in
                func fail(_ reason: Failure) {
                    restore(saved, to: pasteboard)
                    completion(.failure(reason))
                }

                guard let selection = selection, !selection.isEmpty else {
                    return fail(.noSelection)
                }
                guard let source = LayoutTransliterator.detectLanguage(of: selection) else {
                    return fail(.ambiguousLanguage)
                }
                let target = source.opposite
                let converted = LayoutTransliterator.convert(selection, to: target)
                guard converted != selection else {
                    return fail(.nothingToChange)
                }

                pasteboard.clearContents()
                pasteboard.setString(converted, forType: .string)
                let ourChangeCount = pasteboard.changeCount

                post(keyCode: pasteKeyCode)
                InputSourceManager.switchTo(target)

                DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardRestoreDelay) {
                    // Only put the old contents back if nothing newer arrived: a write by
                    // anything else in the meantime is newer than ours and must survive.
                    if pasteboard.changeCount == ourChangeCount {
                        restore(saved, to: pasteboard)
                    }
                    appLog("[LayoutSwitcher] selection converted \(source.rawValue) -> "
                           + "\(target.rawValue), \(selection.count) chars")
                    completion(.success(converted))
                }
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

    /// The selected text of the focused element in the frontmost app, if it publishes one.
    private static func accessibilitySelection() -> String? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let application = AXUIElementCreateApplication(pid)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                application, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let element = focused as! AXUIElement  // type ID checked immediately above

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
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
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
    /// `modifierReleaseTimeout` and proceeds anyway.
    private static func whenModifiersAreReleased(_ work: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(modifierReleaseTimeout)
        let held: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]

        func poll() {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(held).isEmpty || Date() >= deadline {
                work()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
        }
        poll()
    }
}
