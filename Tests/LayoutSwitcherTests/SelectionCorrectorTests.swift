import AppKit
import Testing
@testable import LayoutSwitcher

@Suite @MainActor struct SelectionCorrectorTests {
    @Test func inaccessibleSelectionDoesNotUseClipboard() {
        #expect(SelectionCorrector.selectionText(selectedText: nil, value: nil, range: nil) == nil)
    }

    @Test func selectionCanBeReadFromFieldValueAndUTF16Range() {
        #expect(SelectionCorrector.selectionText(selectedText: nil, value: "🙂 ghbdsn!",
                                                 range: CFRange(location: 3, length: 6)) == "ghbdsn")
        #expect(SelectionCorrector.selectionText(selectedText: "ghbdsn", value: nil,
                                                 range: nil) == "ghbdsn")
    }

    @Test func inconsistentOrInvalidSelectionIsRejected() {
        #expect(SelectionCorrector.selectionText(selectedText: "remote", value: "local",
                                                 range: CFRange(location: 0, length: 5)) == nil)
        for range in [CFRange(location: -1, length: 1), CFRange(location: 0, length: 0),
                      CFRange(location: 0, length: Int.max), CFRange(location: Int.max, length: 1)] {
            #expect(SelectionCorrector.selectionText(selectedText: nil, value: "local", range: range) == nil)
        }
    }
    @Test func restoringAnEmptyPasteboardActuallyClearsIt() {
        let pasteboard = NSPasteboard(name: .init("MacKeySwitchTests.empty"))
        pasteboard.clearContents()
        let saved = SelectionCorrector.snapshot(pasteboard)

        pasteboard.setString("temporary", forType: .string)
        SelectionCorrector.restore(saved, to: pasteboard)

        #expect(pasteboard.pasteboardItems?.isEmpty != false)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func restoringAPasteboardPreservesAllItemTypes() {
        let pasteboard = NSPasteboard(name: .init("MacKeySwitchTests.types"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setString("<b>plain</b>", forType: .html)
        pasteboard.writeObjects([item])
        let saved = SelectionCorrector.snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        SelectionCorrector.restore(saved, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "plain")
        #expect(pasteboard.string(forType: .html) == "<b>plain</b>")
    }

    @Test func writingToAnElementThatRefusesFailsCleanlyRatherThanCrashing() {
        // The system-wide element accepts no attribute writes and cannot be read back
        // either; this exercises exactly the AXError path every genuinely unsupported app
        // takes, without needing one running.
        let element = AXUIElementCreateSystemWide()
        #expect(SelectionCorrector.replaceSelectionViaAccessibility(
            element, with: "привіт", verified: { false }) != .applied)
    }

    @Test func aPromisedItemDeliversItsTextOnlyWhenSomethingReadsIt() {
        // The whole point of the promise: nothing has been handed to the pasteboard yet
        // just by writing the item, and the callback proves exactly when that changes.
        let pasteboard = NSPasteboard(name: .init("MacKeySwitchTests.promise"))
        pasteboard.clearContents()

        var provided = false
        let provider = SelectionCorrector.ConvertedTextProvider(text: "привіт") {
            provided = true
        }
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        pasteboard.writeObjects([item])

        #expect(!provided, "writing the promise must not itself count as a read")
        #expect(pasteboard.string(forType: .string) == "привіт")
        #expect(provided, "reading the string is what must fulfil the promise")
    }

    @Test func uncertainAXWriteMustNotAuthorizeFallback() {
        #expect(SelectionCorrector.replacementResult(write: { .success }, verified: { false }) == .uncertain)
        #expect(SelectionCorrector.replacementResult(write: { .cannotComplete }, verified: { false }) == .uncertain)
        #expect(SelectionCorrector.replacementResult(write: { .attributeUnsupported }, verified: { false }) == .rejected)
        #expect(SelectionCorrector.replacementResult(write: { .success }, verified: { true }) == .applied)
    }

    @Test func replacementEvidenceUsesUTF16AndRequiresOriginalSelection() {
        #expect(SelectionCorrector.expectedReplacementValue(
            value: "🙂 ghbdsn!", range: CFRange(location: 3, length: 6),
            original: "ghbdsn", replacement: "привіт") == "🙂 привіт!")
        #expect(SelectionCorrector.expectedReplacementValue(
            value: "hello", range: CFRange(location: 0, length: Int.max),
            original: "hello", replacement: "world") == nil)
        #expect(SelectionCorrector.expectedReplacementValue(
            value: "hello", range: CFRange(location: 0, length: 5),
            original: "other", replacement: "world") == nil)
    }
}
