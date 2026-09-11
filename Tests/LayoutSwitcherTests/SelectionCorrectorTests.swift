import AppKit
import Testing
@testable import LayoutSwitcher

@Suite @MainActor struct SelectionCorrectorTests {
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
        #expect(!SelectionCorrector.replaceSelectionViaAccessibility(
            element, replacing: "ghbdsn", with: "привіт"))
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
}
