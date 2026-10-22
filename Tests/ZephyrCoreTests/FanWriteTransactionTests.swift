import XCTest
@testable import ZephyrCore

/// Simulated fan registers with a controllable firmware response. Time is
/// virtual: `sleep` advances the clock, so settle windows run instantly.
private final class SimulatedFan: FanRegisterAccess {
    enum Firmware {
        /// Accepts both writes as given.
        case obedient
        /// Overwrites F0Tg with its own value while in automatic mode,
        /// so a target staged before manual mode is lost.
        case overwritesTargetInAuto(Double)
        /// Accepts mode 1, then reverts to mode 3 after `delay`.
        case revertsManual(after: TimeInterval)
        /// Reports manual mode only after `delay`.
        case slowManual(after: TimeInterval)
    }
    var firmware: Firmware = .obedient
    var mode: UInt8 = 3
    var target = 1800.0, actual = 1900.0
    let minimum = 1000.0, maximum = 4900.0
    var clock = Date(timeIntervalSince1970: 0)
    var log: [String] = []
    var targetError: Error?, modeError: Error?, readError: Error?
    var modeWrittenAt: Date?

    func readRegisters() throws -> FanRegisters {
        if let readError { throw readError }
        var shownMode = mode
        switch firmware {
        case .revertsManual(let delay):
            if mode == 1, let at = modeWrittenAt, clock.timeIntervalSince(at) >= delay { mode = 3; shownMode = 3 }
        case .slowManual(let delay):
            if mode == 1, let at = modeWrittenAt, clock.timeIntervalSince(at) < delay { shownMode = 3 }
        default: break
        }
        return FanRegisters(mode: shownMode, targetRPM: target, actualRPM: actual, minimumRPM: minimum, maximumRPM: maximum)
    }
    func writeTarget(rpm: Double) throws {
        log.append("Tg=\(Int(rpm))")
        if let targetError { throw targetError }
        target = rpm
        if case .overwritesTargetInAuto(let own) = firmware, mode != 1 { target = own }
    }
    func writeMode(_ value: UInt8) throws {
        log.append("Md=\(value)")
        if let modeError { throw modeError }
        mode = value; modeWrittenAt = clock
    }
}

/// Rejects the first mode write, as a transiently busy SMC might.
private final class OnceFailingMode: FanRegisterAccess {
    let base: SimulatedFan; private var failed = false
    init(_ base: SimulatedFan) { self.base = base }
    func readRegisters() throws -> FanRegisters { try base.readRegisters() }
    func writeTarget(rpm: Double) throws { try base.writeTarget(rpm: rpm) }
    func writeMode(_ mode: UInt8) throws {
        if !failed { failed = true; base.log.append("Md=\(mode) rejected"); throw FanControlError.hardwareFailure("busy") }
        try base.writeMode(mode)
    }
}

final class FanWriteTransactionTests: XCTestCase {
    private func transaction(_ fan: SimulatedFan, _ plan: FanWritePlan = .standard) -> FanWriteTransaction {
        FanWriteTransaction(fan: fan, plan: plan, clock: { fan.clock }, sleep: { fan.clock.addTimeInterval($0) })
    }

    func testStandardPlanWritesModeBeforeTargetWithoutRetries() throws {
        XCTAssertEqual(FanWritePlan.standard.order, .modeThenTarget)
        XCTAssertEqual(FanWritePlan.standard.reassertions, 0)
        let fan = SimulatedFan()
        try transaction(fan).apply(percent: 100)
        XCTAssertEqual(fan.log, ["Md=1", "Tg=4900"])
        XCTAssertEqual(fan.mode, 1); XCTAssertEqual(fan.target, 4900)
    }

    func testTargetFirstOrderRemainsSelectable() throws {
        let fan = SimulatedFan()
        var plan = FanWritePlan.standard; plan.order = .targetThenMode
        try transaction(fan, plan).apply(percent: 50)
        XCTAssertEqual(fan.log, ["Tg=2450", "Md=1"])
    }

    func testTargetIsClampedToFirmwareFloor() throws {
        let fan = SimulatedFan()
        try transaction(fan).apply(percent: 0)
        XCTAssertEqual(fan.target, 1000)
    }

    /// The reported field failure: target staged in Auto is overwritten.
    func testOverwrittenStagedTargetFailsWithDiagnosableTrace() {
        let fan = SimulatedFan(); fan.firmware = .overwritesTargetInAuto(1834)
        var plan = FanWritePlan.standard; plan.order = .targetThenMode
        XCTAssertThrowsError(try transaction(fan, plan).apply(percent: 100)) { error in
            guard case FanControlError.hardwareFailure(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("expected manual mode 1 at 4900 RPM"), message)
            XCTAssertTrue(message.contains("read mode 1, target 1834 RPM"), message)
            XCTAssertTrue(message.contains("Tg←4900 ok"), message)
            XCTAssertTrue(message.contains("Md←1 ok"), message)
        }
        // Settling is passive: no extra writes without re-assertion evidence.
        XCTAssertEqual(fan.log, ["Tg=4900", "Md=1"])
    }

    func testStandardPlanAvoidsAutoTargetOverwrite() throws {
        let fan = SimulatedFan(); fan.firmware = .overwritesTargetInAuto(1834)
        try transaction(fan).apply(percent: 100)
        XCTAssertEqual(fan.target, 4900)
    }

    func testSlowModeTransitionIsAcceptedWithinSettleWindow() throws {
        let fan = SimulatedFan(); fan.firmware = .slowManual(after: 0.4)
        try transaction(fan).apply(percent: 70)
        XCTAssertEqual(fan.log.count, 2)
        XCTAssertLessThanOrEqual(fan.clock.timeIntervalSince1970, FanWritePlan.standard.settle + 0.2)
    }

    func testModeReversionFailsAndReportsTransitions() {
        let fan = SimulatedFan(); fan.firmware = .revertsManual(after: 0)
        XCTAssertThrowsError(try transaction(fan).apply(percent: 100)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("read mode 3"), error.localizedDescription)
        }
    }

    func testSettleWindowIsBounded() {
        let fan = SimulatedFan(); fan.firmware = .revertsManual(after: 0)
        XCTAssertThrowsError(try transaction(fan).apply(percent: 100))
        XCTAssertLessThanOrEqual(fan.clock.timeIntervalSince1970, FanWritePlan.standard.worstCaseWrite + 0.001)
    }

    func testReassertionIsExplicitAndBounded() {
        let fan = SimulatedFan(); fan.firmware = .revertsManual(after: 0)
        var plan = FanWritePlan.standard; plan.reassertions = 2
        XCTAssertThrowsError(try transaction(fan, plan).apply(percent: 100))
        XCTAssertEqual(fan.log, ["Md=1", "Tg=4900", "Md=1", "Tg=4900", "Md=1", "Tg=4900"])
        XCTAssertEqual(FanWritePlan(order: .targetThenMode, settle: 1, pollInterval: 0.1, reassertions: 99, restoreAttempts: 0).reassertions, 5)
    }

    func testRejectedModeWriteStopsAndNamesTheKey() {
        let fan = SimulatedFan(); fan.modeError = FanControlError.hardwareFailure("kIOReturnNotPrivileged")
        XCTAssertThrowsError(try transaction(fan).apply(percent: 100)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Fan Md write was rejected."), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("kIOReturnNotPrivileged"))
        }
        // The target is never written after a rejected mode.
        XCTAssertEqual(fan.log, ["Md=1"])
    }

    func testUnknownModeIsNeverWritten() {
        let fan = SimulatedFan(); fan.mode = 2
        XCTAssertThrowsError(try transaction(fan).apply(percent: 100))
        XCTAssertTrue(fan.log.isEmpty)
    }

    func testRestoreAcceptsEitherAutomaticModeAndRetriesOnce() throws {
        let fan = SimulatedFan(); fan.mode = 1
        try transaction(fan).restoreAutomatic()
        XCTAssertTrue([0, 3].contains(fan.mode)); XCTAssertEqual(fan.log, ["Md=0"])

        let flaky = OnceFailingMode(SimulatedFan()); flaky.base.mode = 1
        try FanWriteTransaction(fan: flaky, clock: { flaky.base.clock }, sleep: { flaky.base.clock.addTimeInterval($0) }).restoreAutomatic()
        XCTAssertEqual(flaky.base.log, ["Md=0 rejected", "Md=0"])
        XCTAssertEqual(flaky.base.mode, 0)
    }

    func testRestoreFailureIsReportedAfterBoundedAttempts() {
        let fan = SimulatedFan(); fan.mode = 1; fan.modeError = FanControlError.hardwareFailure("rejected")
        XCTAssertThrowsError(try transaction(fan).restoreAutomatic())
        XCTAssertEqual(fan.log.count, FanWritePlan.standard.restoreAttempts)
    }

    func testTraceIsBoundedForLongSettles() {
        let fan = SimulatedFan(); fan.firmware = .revertsManual(after: 0)
        var plan = FanWritePlan.standard; plan.reassertions = 5
        XCTAssertThrowsError(try transaction(fan, plan).apply(percent: 100)) { error in
            XCTAssertLessThan(error.localizedDescription.count, 1500)
        }
    }

    func testClientDeadlinesCoverHelperWorstCase() {
        // A heartbeat can wait behind a failed write plus its rollback on the
        // helper's serial queue. The client must not time out first, because a
        // timeout drops the connection and therefore the user's lease.
        XCTAssertGreaterThan(FanSafety.commandReplyTimeout, FanSafety.commandWorstCase + 4)
        XCTAssertLessThan(FanSafety.commandReplyTimeout, FanSafety.leaseTimeout)
    }

    // MARK: Rollback through the recovery policy

    /// The helper's real composition: policy + transaction + registers.
    private final class TransactionDriver: FanRecoveryDriver {
        let fan: SimulatedFan; let transaction: FanWriteTransaction
        init(_ fan: SimulatedFan) {
            self.fan = fan
            transaction = FanWriteTransaction(fan: fan, clock: { fan.clock }, sleep: { fan.clock.addTimeInterval($0) })
        }
        func snapshot() throws -> FanSnapshot {
            let r = try fan.readRegisters()
            return FanSnapshot(currentRPM: r.actualRPM, minimumRPM: r.minimumRPM, maximumRPM: r.maximumRPM,
                               targetPercent: r.automatic ? nil : r.targetRPM / r.maximumRPM * 100, automatic: r.automatic,
                               temperatureCelsius: 70, sampledAt: fan.clock)
        }
        func fanSnapshot() throws -> FanReadback {
            let s = try snapshot()
            return FanReadback(currentRPM: s.currentRPM, minimumRPM: s.minimumRPM, maximumRPM: s.maximumRPM, targetPercent: s.targetPercent, automatic: s.automatic)
        }
        func set(percent: Double) throws { try transaction.apply(percent: percent) }
        func restoreAutomatic() throws { try transaction.restoreAutomatic() }
        func automatic() throws -> Bool { try fanSnapshot().automatic }
    }

    /// Mode accepted, target rejected: the fan must not stay manual at the
    /// previous target.
    func testRejectedTargetAfterAcceptedModeRollsBackToAuto() {
        let fan = SimulatedFan(); fan.targetError = FanControlError.hardwareFailure("rejected")
        let driver = TransactionDriver(fan)
        let policy = FanRecoveryController(driver: driver, now: { fan.clock })
        let session = UUID()
        XCTAssertThrowsError(try policy.set(percent: 100, session: session)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Fan Tg write was rejected."), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.hasSuffix("Automatic control was restored and verified."), error.localizedDescription)
        }
        XCTAssertEqual(fan.log, ["Md=1", "Tg=4900", "Md=0"])
        XCTAssertTrue([0, 3].contains(fan.mode)); XCTAssertFalse(policy.state.owns(session))
    }

    func testReadbackFailureAfterWritesRollsBackToAuto() {
        let fan = SimulatedFan(); fan.firmware = .revertsManual(after: 0)
        let policy = FanRecoveryController(driver: TransactionDriver(fan), now: { fan.clock })
        XCTAssertThrowsError(try policy.set(percent: 100, session: UUID()))
        XCTAssertEqual(fan.log, ["Md=1", "Tg=4900", "Md=0"])
        XCTAssertTrue([0, 3].contains(fan.mode))
    }

    /// Firmware that takes control back after a verified write is detected
    /// by the safety tick, which releases the lease without writing again.
    func testLateFirmwareReversionReleasesLeaseWithoutAnotherWrite() throws {
        let fan = SimulatedFan(); fan.firmware = .revertsManual(after: 3)
        let policy = FanRecoveryController(driver: TransactionDriver(fan), now: { fan.clock })
        let session = UUID()
        _ = try policy.set(percent: 100, session: session)
        fan.clock.addTimeInterval(5); policy.tick()
        XCTAssertFalse(policy.state.owns(session))
        XCTAssertEqual(fan.log, ["Md=1", "Tg=4900"])
    }

    func testVerifiedMaximumThenAutoEndToEnd() throws {
        let fan = SimulatedFan(); fan.firmware = .overwritesTargetInAuto(1834)
        let policy = FanRecoveryController(driver: TransactionDriver(fan), now: { fan.clock })
        let session = UUID()
        let applied = try policy.set(percent: 100, session: session)
        XCTAssertEqual(applied.targetPercent ?? 0, 100, accuracy: 0.001); XCTAssertFalse(applied.automatic)
        let restored = try policy.restore(session)
        XCTAssertTrue(restored.automatic); XCTAssertFalse(policy.state.owns(session))
        XCTAssertEqual(fan.log, ["Md=1", "Tg=4900", "Md=0"])
    }
}
