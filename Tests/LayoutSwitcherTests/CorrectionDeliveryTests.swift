import Testing
@testable import LayoutSwitcher

@Suite struct CorrectionDeliveryTests {
    @Test func interruptionAtEveryOutputBoundaryStopsTheRemainingEvents() {
        let expected: [CorrectionDelivery.Step] = [
            .backspace, .backspace, .switchLayout,
            .character("а"), .character("б"), .space
        ]
        for boundary in 0...expected.count {
            var posted: [CorrectionDelivery.Step] = []
            let completed = CorrectionDelivery.execute(
                deleteCount: 2, text: "аб", restoreSpace: true, erasePause: {}
            ) { step in
                guard posted.count < boundary else { return false }
                posted.append(step)
                return true
            }
            #expect(posted == Array(expected.prefix(boundary)))
            #expect(completed == (boundary == expected.count))
        }
    }

    @Test func losingFocusDuringErasePauseDoesNotSwitchOrRetype() {
        var valid = true
        var posted: [CorrectionDelivery.Step] = []
        let completed = CorrectionDelivery.execute(
            deleteCount: 1, text: "а", restoreSpace: true,
            erasePause: { valid = false }
        ) { step in
            guard valid else { return false }
            posted.append(step)
            return true
        }
        #expect(!completed)
        #expect(posted == [.backspace])
    }

    @Test func invalidationBetweenDeliveryAndPublicationDiscardsUndo() {
        var valid = true
        var published = false
        var discarded = false
        let completion = {
            CorrectionDelivery.publish(completed: true, contextIsValid: { valid },
                                       success: { published = true },
                                       discard: { discarded = true })
        }
        // A mouse/app event runs on main before the queued completion.
        valid = false
        completion()
        #expect(!published)
        #expect(discarded)
    }

    @Test func incompleteDeliveryNeverPublishesEvenWithUnchangedFocus() {
        var published = false
        var discarded = false
        CorrectionDelivery.publish(completed: false, contextIsValid: { true },
                                   success: { published = true },
                                   discard: { discarded = true })
        #expect(!published)
        #expect(discarded)
    }

    @Test func invalidDeleteCountPostsNothing() {
        var posted = false
        #expect(!CorrectionDelivery.execute(deleteCount: 66, text: "а", restoreSpace: true,
                                            erasePause: {}) { _ in
            posted = true
            return true
        })
        #expect(!posted)
    }
}
