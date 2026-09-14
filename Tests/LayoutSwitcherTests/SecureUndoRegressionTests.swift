import Testing
@testable import LayoutSwitcher

@Suite struct SecureUndoRegressionTests {
    @Test(arguments: [SecureFieldState.secure, .unknown])
    func unsafeFieldRejectsAndDiscardsUndo(field: SecureFieldState) {
        let h = Harness()
        h.type("ghbdsn")
        #expect(h.correct(h.space()) != nil)
        h.env.field = field
        #expect(h.engine.undoPlan(isCorrecting: false) == nil)
        h.env.field = .notSecure
        #expect(h.engine.undoPlan(isCorrecting: false) == nil)
    }

    @Test func secureInputTypingDiscardsUndo() {
        let h = Harness()
        h.type("ghbdsn")
        #expect(h.correct(h.space()) != nil)
        h.env.isSystemSecureInputEnabled = true
        h.type("secret")
        h.env.isSystemSecureInputEnabled = false
        #expect(h.engine.undoPlan(isCorrecting: false) == nil)
    }

    @Test func secureInputWithoutTypingRejectsUndo() {
        let h = Harness()
        h.type("ghbdsn")
        #expect(h.correct(h.space()) != nil)
        h.env.isSystemSecureInputEnabled = true
        #expect(h.engine.undoPlan(isCorrecting: false) == nil)
    }
}
