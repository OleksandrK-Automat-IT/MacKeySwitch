import Foundation

/// One active operation. Invalidation and final publication use this same state;
/// callers must finish on main alongside the engine's result callbacks.
final class CorrectionOperation {
    private let lock = NSLock()
    private var active = false
    private var valid = false

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }
    var canContinue: Bool {
        lock.lock(); defer { lock.unlock() }
        return active && valid
    }
    func begin() {
        lock.lock(); defer { lock.unlock() }
        precondition(!active)
        active = true
        valid = true
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        valid = false
    }
    @discardableResult
    func finish(completed: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let publish = active && valid && completed
        active = false
        valid = false
        return publish
    }
}
