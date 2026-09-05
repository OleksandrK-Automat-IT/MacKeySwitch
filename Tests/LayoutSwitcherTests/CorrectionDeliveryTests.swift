import Testing
import Foundation
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

    @Test @MainActor func invalidationBetweenDeliveryAndPublicationDiscardsUndo() async {
        let operation = CorrectionOperation()
        operation.begin()
        let delivered = CorrectionDelivery.execute(deleteCount: 1, text: "а", restoreSpace: true,
                                                  erasePause: {}) { _ in operation.canContinue }
        #expect(delivered)
        let published = await withCheckedContinuation { continuation in
            DispatchQueue.main.async { operation.invalidate() }
            DispatchQueue.main.async {
                continuation.resume(returning: operation.finish(completed: delivered))
            }
        }
        #expect(!published)
        #expect(!operation.isActive)
        operation.begin()
        #expect(operation.finish(completed: true))
    }

    @Test func incompleteDeliveryNeverPublishesEvenWithUnchangedFocus() {
        let operation = CorrectionOperation()
        operation.begin()
        #expect(!operation.finish(completed: false))
        #expect(!operation.canContinue)
        #expect(!operation.finish(completed: true))
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
