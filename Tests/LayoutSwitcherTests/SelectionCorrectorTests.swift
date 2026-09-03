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
}
