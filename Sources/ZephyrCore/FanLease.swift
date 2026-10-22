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

public protocol FanRecoveryDriver {
    func snapshot() throws -> FanSnapshot
    func fanSnapshot() throws -> FanReadback
    func set(percent: Double) throws
    func restoreAutomatic() throws
    func automatic() throws -> Bool
}

/// Synchronous recovery policy. The helper owns queueing and timers; this
/// object owns all write/readback failure boundaries and is easy to exercise
/// with a fake driver in tests.
public final class FanRecoveryController {
    public let driver: FanRecoveryDriver
    private let now: () -> Date
    public private(set) var state = FanRecoveryState()
    public private(set) var lastHeartbeat: Date?
    private var lastValidSnapshot: FanSnapshot?
    private var lastAutomaticReadback: FanReadback?

    public init(driver: FanRecoveryDriver, now: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.now = now
    }

    public func disconnect(_ session: UUID) {
        guard state.owns(session) else { return }
        state.requestRestore(session)
        lastHeartbeat = nil
        _ = attemptRestore(session)
    }

    public func heartbeat(_ session: UUID) {
        guard state.owns(session), state.manual, !state.restorePending else { return }
        lastHeartbeat = now()
    }

    /// Adopt a journaled lease only after the adapter has independently
    /// verified that the current hardware target belongs to that session.
    public func recoverOwnedLease(_ session: UUID) {
        guard state.claim(session) else { return }
        state.didSetManual(session)
        state.requestRestore(session)
    }

    @discardableResult
    public func set(percent: Double, session: UUID, beforeWrite: ((FanSnapshot) throws -> Void)? = nil) throws -> FanSnapshot {
        let requested = try FanSafety.validate(percent: percent)
        let wasOwner = state.owns(session)
        guard state.claim(session), !state.restorePending else { throw FanControlError.unavailable }
        var writeAttempted = false
        var keepMaximumCooling = false
        do {
            let before = try driver.snapshot()
            lastValidSnapshot = before
            guard FanSafety.hasReliableReading(before, now: now()),
                  lastHeartbeat.map({ now().timeIntervalSince($0) <= FanSafety.leaseTimeout }) ?? true else {
                throw FanControlError.staleSensor
            }
            guard before.fanCount == 1 else {
                throw FanControlError.hardwareFailure("Manual control for multiple-fan Macs is not supported yet.")
            }
            if before.temperatureCelsius >= FanSafety.criticalTemperatureCelsius && requested != 100 {
                keepMaximumCooling = wasOwner && FanSafety.isMaximumCooling(before)
                throw FanControlError.tooHot(before.temperatureCelsius)
            }
            lastHeartbeat = now()
            try beforeWrite?(before)
            writeAttempted = true
            try driver.set(percent: requested)
            let after = try driver.snapshot()
            lastValidSnapshot = after
            let expected = FanSafety.hardwareFloorClampedPercent(requested, snapshot: after)
            guard !after.automatic,
                  FanSafety.matchesRequestedPercent(after.targetPercent, expected: expected),
                  !FanSafety.shouldRestoreAutomatic(snapshot: after, now: now(), lastHeartbeat: lastHeartbeat) else {
                throw FanControlError.hardwareFailure("Fan target did not verify after setting.")
            }
            state.didSetManual(session)
            return after
        } catch {
            if writeAttempted && state.owns(session) {
                state.requestRestore(session)
                _ = attemptRestore(session)
            }
            if !writeAttempted && wasOwner && state.owns(session) && !keepMaximumCooling {
                state.requestRestore(session)
                _ = attemptRestore(session)
            } else if !writeAttempted && !wasOwner && state.owns(session) {
                state.restoreConfirmed(session)
            }
            throw error
        }
    }

    @discardableResult
    public func restore(_ session: UUID) throws -> FanSnapshot {
        guard state.owns(session) else { throw FanControlError.unavailable }
        state.requestRestore(session)
        guard attemptRestore(session) else {
            throw FanControlError.hardwareFailure("Automatic mode did not verify after restore.")
        }
        guard let fan = lastAutomaticReadback, let previous = lastValidSnapshot else { throw FanControlError.hardwareFailure("Automatic mode restored, but no prior temperature sample is available.") }
        return FanSnapshot(currentRPM: fan.currentRPM, minimumRPM: fan.minimumRPM,
                           maximumRPM: fan.maximumRPM, targetPercent: fan.targetPercent,
                           automatic: true, temperatureCelsius: previous.temperatureCelsius,
                           sampledAt: previous.sampledAt, fanCount: previous.fanCount)
    }

    public func tick() {
        guard let owner = state.owner else { return }
        if state.restorePending { _ = attemptRestore(owner); return }
        guard let snapshot = try? driver.snapshot() else {
            state.requestRestore(owner); _ = attemptRestore(owner); return
        }
        lastValidSnapshot = snapshot
        if snapshot.automatic {
            state.restoreConfirmed(owner); lastHeartbeat = nil
            return
        }
        if FanSafety.shouldRestoreAutomatic(snapshot: snapshot, now: now(), lastHeartbeat: lastHeartbeat) {
            state.requestRestore(owner); _ = attemptRestore(owner)
        }
    }

    @discardableResult
    private func attemptRestore(_ session: UUID) -> Bool {
        guard state.owns(session), state.restorePending else { return false }
        do {
            try driver.restoreAutomatic()
            let fan = try driver.fanSnapshot()
            guard fan.automatic else { return false }
            lastAutomaticReadback = fan
            state.restoreConfirmed(session)
            lastHeartbeat = nil
            return true
        } catch { return false }
    }
}
