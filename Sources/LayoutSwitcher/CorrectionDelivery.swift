import Foundation

/// Runs one bounded output step at a time. The caller checks the live editing context
/// and posts each step together on main, so an invalidation cannot interleave them.
enum CorrectionDelivery {
    enum Step: Equatable {
        case backspace
        case switchLayout
        case character(Character)
        case space
    }

    static func execute(deleteCount: Int, text: String, restoreSpace: Bool,
                        erasePause: () -> Void,
                        send: (Step) -> Bool) -> Bool {
        guard (0...CorrectionEngine.maxBufferLength + 1).contains(deleteCount) else {
            return false
        }
        for _ in 0..<deleteCount {
            guard send(.backspace) else { return false }
        }
        erasePause()
        guard send(.switchLayout) else { return false }
        for character in text {
            guard send(.character(character)) else { return false }
        }
        if restoreSpace, !send(.space) { return false }
        return true
    }

}
