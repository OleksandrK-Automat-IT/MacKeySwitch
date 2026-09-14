import AppKit

/// Main-thread clipboard lease. Readers (including clipboard history utilities) are
/// deliberately not acknowledgements. Only verified target text permits restoration.
final class SelectionPasteTransaction {
    enum State: Equatable { case pending, confirmed, unconfirmed }
    private let pasteboard: NSPasteboard
    private let saved: SelectionCorrector.PasteboardSnapshot
    private let changeCount: Int
    private(set) var state: State = .pending

    init?(pasteboard: NSPasteboard, saved: SelectionCorrector.PasteboardSnapshot, text: String) {
        self.pasteboard = pasteboard
        self.saved = saved
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            SelectionCorrector.restore(saved, to: pasteboard)
            return nil
        }
        changeCount = pasteboard.changeCount
    }

    @discardableResult
    func update(valid: Bool, verified: Bool, timedOut: Bool) -> State {
        guard state == .pending else { return state }
        if valid && verified {
            if pasteboard.changeCount == changeCount {
                SelectionCorrector.restore(saved, to: pasteboard)
            }
            state = .confirmed
        } else if !valid || timedOut || pasteboard.changeCount != changeCount {
            // A posted Cmd+V cannot be recalled. Do not replace its payload with the
            // old clipboard just because a deadline expired or focus moved.
            state = .unconfirmed
        }
        return state
    }
}
