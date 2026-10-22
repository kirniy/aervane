import Foundation

public final class FanLeaseCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?
    public init() {}
    public func claim(_ session: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; if owner == nil || owner == session { owner = session; return true }; return false }
    public func owns(_ session: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return owner == session }
    public func release(_ session: UUID) { lock.lock(); defer { lock.unlock() }; if owner == session { owner = nil } }
}

/// The small, deterministic part of disconnect recovery. The helper adapts
/// this state to its serial queue and hardware driver; keeping the transitions
/// here makes failure boundaries testable without touching AppleSMC.
public struct FanRecoveryState: Equatable, Sendable {
    public private(set) var owner: UUID?
    public private(set) var restorePending = false
    public private(set) var manual = false

    public init() {}

    @discardableResult
    public mutating func claim(_ session: UUID) -> Bool {
        guard owner == nil || owner == session else { return false }
        owner = session
        return true
    }

    public func owns(_ session: UUID) -> Bool { owner == session }

    public mutating func didSetManual(_ session: UUID) {
        guard owner == session else { return }
        manual = true
        restorePending = false
    }

    public mutating func requestRestore(_ session: UUID) {
        guard owner == session else { return }
        restorePending = true
    }

    public mutating func restoreConfirmed(_ session: UUID) {
        guard owner == session else { return }
        owner = nil
        manual = false
        restorePending = false
    }

    public mutating func releaseIfAutomatic(_ session: UUID, automatic: Bool) {
        guard automatic else { return }
        restoreConfirmed(session)
    }
}
