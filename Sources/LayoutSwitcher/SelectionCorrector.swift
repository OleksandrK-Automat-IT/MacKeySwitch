import ApplicationServices
import Cocoa

/// Converts the current selection to the other layout, on demand.
///
/// The automatic corrector only ever sees one word, and only while it is being typed. This
/// covers what it cannot: text already on screen, pasted from elsewhere, or a whole
/// sentence noticed after the fact. The user selects it and presses the shortcut.
///
/// Replacement goes through the pasteboard rather than synthesised keystrokes. Typing a
/// long selection back one character at a time takes seconds, and every one of those
/// characters is a chance for the user to type something in the middle of it. A paste is
/// one event. The cost is that the pasteboard is borrowed, so it is snapshotted and put
/// back — see `replaceSelection`.
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

    @discardableResult
    static func correctSelection() -> Result<String, Failure> {
        guard AXIsProcessTrusted() else { return .failure(.noAccessibility) }
        guard let selection = readSelection(), !selection.isEmpty else {
            return .failure(.noSelection)
        }
        guard let sourceLanguage = LayoutTransliterator.detectLanguage(of: selection) else {
            return .failure(.ambiguousLanguage)
        }

        let target = sourceLanguage.opposite
        let converted = LayoutTransliterator.convert(selection, to: target)
        guard converted != selection else { return .failure(.nothingToChange) }

        replaceSelection(with: converted)
        InputSourceManager.switchTo(target)

        debugLog("[LayoutSwitcher] Selection converted \(sourceLanguage.rawValue) -> \(target.rawValue)")
        return .success(converted)
    }

    // MARK: - Reading

    /// The selected text of the focused element in the frontmost app.
    private static func readSelection() -> String? {
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

    // MARK: - Replacing

    /// Put `text` on the pasteboard, paste it over the selection, then restore whatever the
    /// user had there.
    ///
    /// Restoring is conditional on `changeCount`: if anything else wrote to the pasteboard
    /// in the meantime, that write is newer than ours and must not be clobbered. Note this
    /// does briefly place the converted text on the pasteboard, where a clipboard manager
    /// may record it.
    private static func replaceSelection(with text: String) {
        let pasteboard = NSPasteboard.general

        // Items read from a pasteboard are invalidated by clearContents(), so copy their
        // data out before clearing rather than holding references to them.
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        postPaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardRestoreDelay) {
            guard pasteboard.changeCount == ourChangeCount else { return }
            pasteboard.clearContents()
            if !saved.isEmpty {
                pasteboard.writeObjects(saved)
            }
        }
    }

    private static func postPaste() {
        let commandV: CGKeyCode = 0x09 // 'v'
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: commandV, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: commandV, keyDown: false)
        else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
