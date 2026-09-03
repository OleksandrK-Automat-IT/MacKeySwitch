import Testing
import AppKit
@testable import LayoutSwitcher

@Suite @MainActor struct SettingsWindowTests {

    private func window() -> EscapeClosableWindow {
        EscapeClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
    }

    @Test func escapeAsksTheWindowToClose() {
        // Escape arrives as cancelOperation once nothing in the responder chain wants it.
        let w = window()
        var closed = false
        w.onCancel = { closed = true }
        w.cancelOperation(nil)
        #expect(closed)
    }

    @Test func withoutAHandlerItClosesItself() {
        let w = window()
        w.isReleasedWhenClosed = false
        w.orderFront(nil)
        w.cancelOperation(nil)
        #expect(!w.isVisible)
    }
}
