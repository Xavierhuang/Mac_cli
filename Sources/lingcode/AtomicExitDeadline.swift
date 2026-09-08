import Foundation

/// Deadline for the REPL's "press Ctrl-C again to exit" window.
///
/// Lives behind a lock for the same reason `AtomicBool` does: the SIGINT
/// DispatchSource handler and the REPL's own turn loop touch it from different
/// threads, and a torn read here would either quit on a single press or refuse
/// to quit on two.
///
/// Stored as a `timeIntervalSinceReferenceDate` rather than a `Date` so the
/// handler never allocates — it runs in signal-delivery context.
final class AtomicExitDeadline: @unchecked Sendable {
    private var deadline: TimeInterval?
    private let lock = NSLock()

    /// True when `now` still falls inside a previously armed window. Consumes
    /// nothing — the caller exits on true, so there is no state left to reset.
    func isArmed(at now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let deadline else { return false }
        return now <= deadline
    }

    func arm(until newDeadline: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        deadline = newDeadline
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        deadline = nil
    }
}
