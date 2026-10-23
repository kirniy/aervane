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
    func restoreAutomatic(fans: [Int]?) throws
    func automatic() throws -> Bool
}

public extension FanRecoveryDriver {
    /// Recovery may restrict restoration to fans attributed by the journal.
    /// Legacy drivers retain their all-fan behavior through this default.
    func restoreAutomatic(fans: [Int]?) throws { try restoreAutomatic() }
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
    /// The fans the current lease wrote. A different set later is a
    /// topology change: the watchdog restores Auto rather than guess.
    public private(set) var ownedFans: [Int]?

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
    public func recoverOwnedLease(_ session: UUID, fans: [Int]? = nil) {
        guard state.claim(session) else { return }
        ownedFans = fans
        state.didSetManual(session)
        state.requestRestore(session)
    }

    @discardableResult
    public func set(percent: Double, session: UUID, beforeWrite: ((FanSnapshot) throws -> Void)? = nil) throws -> FanSnapshot {
        let requested = try FanSafety.validate(percent: percent)
        let wasOwner = state.owns(session)
        guard state.claim(session) else { throw FanControlError.unavailable }
        guard !state.restorePending else {
            throw FanControlError.hardwareFailure("Automatic control is still being restored and verified. Try again in a few seconds.")
        }
        var writeAttempted = false
        do {
            let before = try driver.snapshot()
            lastValidSnapshot = before
            guard FanSafety.hasReliableReading(before, now: now()),
                  lastHeartbeat.map({ now().timeIntervalSince($0) <= FanSafety.leaseTimeout }) ?? true else {
                throw FanControlError.staleSensor
            }
            // Preflight every fan before the first write: a complete,
            // valid inventory and a known control path.
            guard !before.fans.isEmpty else { throw FanControlError.unavailable }
            guard before.isConsistent else {
                throw FanControlError.hardwareFailure("Fan readings are incomplete (\(before.fans.count) of \(before.fanCount) fans valid). Nothing was changed.")
            }
            if let control = before.control, !control.isSupported {
                throw FanControlError.hardwareFailure(control.message ?? "Fan control is unavailable on this Mac.")
            }
            if let owned = ownedFans, owned != before.fans.map(\.index) {
                throw FanControlError.hardwareFailure("The fan set changed while Aervane controlled it. Nothing was changed.")
            }
            lastHeartbeat = now()
            try beforeWrite?(before)
            writeAttempted = true
            ownedFans = before.fans.map(\.index)
            try driver.set(percent: requested)
            let after = try driver.snapshot()
            lastValidSnapshot = after
            if let mismatch = Self.verify(after, requested: requested, fans: ownedFans ?? []) {
                throw FanControlError.hardwareFailure("Fan target did not verify after setting: \(mismatch).")
            }
            guard !FanSafety.shouldRestoreAutomatic(snapshot: after, now: now(), lastHeartbeat: lastHeartbeat, fanIndices: ownedFans) else {
                throw FanControlError.hardwareFailure("Fan reached the target, but the post-write safety check failed (hottest \(Int(after.temperatureCelsius.rounded()))°C).")
            }
            state.didSetManual(session)
            return after
        } catch {
            var rolledBack: Bool?
            if writeAttempted && state.owns(session) {
                state.requestRestore(session)
                rolledBack = attemptRestore(session)
            }
            if !writeAttempted && wasOwner && state.owns(session) {
                state.requestRestore(session)
                rolledBack = attemptRestore(session)
            } else if !writeAttempted && !wasOwner && state.owns(session) {
                state.restoreConfirmed(session)
            }
            // Tell the caller what state the hardware was left in, not only
            // why the command failed.
            if case FanControlError.hardwareFailure(let message) = error, let rolledBack {
                throw FanControlError.hardwareFailure(message + (rolledBack
                    ? " Automatic control was restored and verified."
                    : " Automatic restore did not verify yet; the helper keeps retrying."))
            }
            throw error
        }
    }

    /// Nil when every leased fan reads manual at max(requested, its floor);
    /// otherwise what was read, fan by fan on multi-fan Macs.
    static func verify(_ after: FanSnapshot, requested: Double, fans: [Int]) -> String? {
        guard after.isConsistent, after.fans.map(\.index) == fans else {
            return "expected fans \(fans), read \(after.fans.map(\.index)) of \(after.fanCount)"
        }
        if after.control?.usesFtst == true && after.aggregateGate != true {
            return "expected Ftst gate 1, read \(after.aggregateGate == nil ? "unavailable" : "0")"
        }
        let multiple = fans.count > 1
        let problems = after.fans.compactMap { fan -> String? in
            let expected = FanSafety.expectedPercent(requested, fan: fan)
            if fan.mode == .manual, FanSafety.matchesRequestedPercent(fan.targetPercent, expected: expected) { return nil }
            let observed = fan.mode == .automatic ? "Auto" : fan.mode == .unknown ? "unknown mode"
                : fan.targetPercent.map { String(format: "manual %.1f%%", $0) } ?? "manual, no target"
            return "\(multiple ? "fan \(fan.index) " : "")expected \(Int(expected.rounded()))%, read \(observed)"
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    @discardableResult
    public func restore(_ session: UUID) throws -> FanSnapshot {
        guard state.owns(session) else { throw FanControlError.notOwner }
        state.requestRestore(session)
        guard attemptRestore(session) else {
            throw FanControlError.hardwareFailure("Automatic mode did not verify after restore.")
        }
        // Report a fresh reading when one is available, so the reply never
        // pairs the restored fans with an old sample time as if it were new.
        if let fresh = try? driver.snapshot(), fresh.automatic {
            lastValidSnapshot = fresh
            return fresh
        }
        guard let fan = lastAutomaticReadback, let previous = lastValidSnapshot else { throw FanControlError.hardwareFailure("Automatic mode restored, but no prior temperature sample is available.") }
        return FanSnapshot(fans: fan.fans, temperatureCelsius: previous.temperatureCelsius,
                           sampledAt: previous.sampledAt, control: previous.control)
    }

    public func tick() {
        guard let owner = state.owner else { return }
        if state.restorePending { _ = attemptRestore(owner); return }
        guard let snapshot = try? driver.snapshot() else {
            state.requestRestore(owner); _ = attemptRestore(owner); return
        }
        lastValidSnapshot = snapshot
        if snapshot.automatic {
            state.restoreConfirmed(owner); lastHeartbeat = nil; ownedFans = nil
            return
        }
        if FanSafety.shouldRestoreAutomatic(snapshot: snapshot, now: now(), lastHeartbeat: lastHeartbeat, fanIndices: ownedFans) {
            state.requestRestore(owner); _ = attemptRestore(owner)
        }
    }

    @discardableResult
    private func attemptRestore(_ session: UUID) -> Bool {
        guard state.owns(session), state.restorePending else { return false }
        do {
            try driver.restoreAutomatic(fans: ownedFans)
            let fan = try driver.fanSnapshot()
            guard fan.automatic else { return false }
            lastAutomaticReadback = fan
            state.restoreConfirmed(session)
            lastHeartbeat = nil; ownedFans = nil
            return true
        } catch { return false }
    }
}
