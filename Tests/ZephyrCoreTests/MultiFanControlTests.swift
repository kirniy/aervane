import XCTest
@testable import ZephyrCore

/// Linked multi-fan writes through the production SMCFanBank over a byte-level
/// fake register file: preflight, per-fan encoding, rollback, bounded timing.
final class MultiFanControlTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 0)

    private func transaction(_ smc: FakeSMC, scheme: FanModeScheme = .uppercase, fans: [Int]? = nil,
                             plan: FanWritePlan = .standard) -> FanWriteTransaction {
        let indices = fans ?? (0..<Int((try? SMCDecoder.uint8(smc.registers["FNum"]!)) ?? 0)).map { $0 }
        return FanWriteTransaction(bank: SMCFanBank(smc: smc, scheme: scheme, fans: indices), plan: plan,
                                   clock: { [unowned self] in self.clock }, sleep: { [unowned self] in self.clock.addTimeInterval($0) })
    }

    func testLinkedPercentIsProportionalToEachMaximumAndClampedToEachMinimum() throws {
        // Fan 0 flt, fan 1 fpe2: mixed target encodings on one Mac.
        let smc = FakeSMC.obedient(fans: [(1200, 5000), (2000, 6000)], fpe2: [1])
        try transaction(smc).apply(percent: 30)
        XCTAssertEqual(smc.writes, ["F0Md=1", "F1Md=1", "F0Tg=1500", "F1Tg=2000"], "all modes, then all targets")
        XCTAssertEqual(smc.registers["F0Tg"]?.dataType, .flt); XCTAssertEqual(smc.registers["F1Tg"]?.dataType, .fpe2)
        XCTAssertEqual(smc.registers["F1Tg"]?.bytes, [0x1F, 0x40], "2000 RPM as fpe2")
        smc.clearLog()
        try transaction(smc).apply(percent: 80)
        XCTAssertEqual(smc.speed("F0Tg"), 4000); XCTAssertEqual(smc.speed("F1Tg"), 4800)
    }

    func testIntelMaskWritesOnlyParticipatingBits() throws {
        let smc = FakeSMC.obedient(fans: [(1300, 6000), (1200, 5500)], scheme: .legacyMask, fpe2: [0, 1])
        smc.setMask(0b1000_0000_0000_0100)   // bits 2 and 15 are not ours
        try transaction(smc, scheme: .legacyMask).apply(percent: 100)
        XCTAssertEqual(smc.mask, 0b1000_0000_0000_0111)
        XCTAssertEqual(smc.speed("F0Tg"), 6000); XCTAssertEqual(smc.speed("F1Tg"), 5500)
        try transaction(smc, scheme: .legacyMask).restoreAutomatic()
        XCTAssertEqual(smc.mask, 0b1000_0000_0000_0100, "restore clears only our bits")
        XCTAssertEqual(FanModeMask.updating(0xFFFF, fan: 9, manual: false), 0xFDFF)
        XCTAssertEqual(FanModeMask.updating(0x0000, fan: 0, manual: true), 0x0001)
    }

    func testMaskWriteIsSkippedWhenTheBitAlreadyHasTheValue() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000)], scheme: .legacyMask)
        let bank = SMCFanBank(smc: smc, scheme: .legacyMask, fans: [0])
        try bank.writeMode(fan: 0, 0)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testLowercaseSchemeWritesLowercaseKeys() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)], scheme: .lowercase)
        try transaction(smc, scheme: .lowercase).apply(percent: 50)
        XCTAssertEqual(Array(smc.writes.prefix(2)), ["F0md=1", "F1md=1"])
        XCTAssertNil(smc.registers["F0Md"])
    }

    func testPreflightReadsEveryFanBeforeTheFirstWrite() {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000), (1000, 5000)])
        smc.transient.insert("F2Mx")
        XCTAssertThrowsError(try transaction(smc).apply(percent: 60)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("Fan 2 readback failed."), $0.localizedDescription)
        }
        XCTAssertTrue(smc.writes.isEmpty)
        smc.transient.removeAll(); smc.set(SMCEncoder.uint8(2, key: "F1Md"))
        XCTAssertThrowsError(try transaction(smc).apply(percent: 60))
        XCTAssertTrue(smc.writes.isEmpty, "an unknown mode on any fan blocks every write")
    }

    func testBankRefusesOutOfRangeTargetsAndForeignFans() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)])
        let bank = SMCFanBank(smc: smc, scheme: .uppercase, fans: [0])
        XCTAssertThrowsError(try bank.writeTarget(fan: 0, rpm: 5200))
        XCTAssertThrowsError(try bank.writeTarget(fan: 0, rpm: 400))
        XCTAssertThrowsError(try bank.writeTarget(fan: 1, rpm: 3000), "fan 1 does not participate")
        XCTAssertThrowsError(try bank.writeMode(fan: 0, 3), "only 0 and 1 are ever written")
        smc.set(SMCEncoder.uint8(7, key: "F0Md"))
        XCTAssertThrowsError(try bank.writeMode(fan: 0, 1), "an unrecognized current mode is not overwritten")
        XCTAssertTrue(smc.writes.isEmpty)
        try bank.writeTarget(fan: 0, rpm: 5000.6)   // float rounding beyond Mx is clamped, not rejected
        XCTAssertEqual(smc.speed("F0Tg"), 5000)
    }

    func testRestoreContinuesAfterAnIndividualFanFails() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000), (1000, 5000)])
        try transaction(smc).apply(percent: 70)
        smc.clearLog(); smc.rejectWrites = ["F1Md"]
        XCTAssertThrowsError(try transaction(smc).restoreAutomatic()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Not automatic: fan 1."), error.localizedDescription)
        }
        XCTAssertEqual(smc.mode(0), 0); XCTAssertEqual(smc.mode(2), 0); XCTAssertEqual(smc.mode(1), 1)
        // Fans already verified are not written again on the retry.
        XCTAssertEqual(smc.writes, ["F0Md=0", "F1Md=0 rejected", "F2Md=0", "F1Md=0 rejected"])
    }

    func testTransientRestoreFailureIsRetriedWithinTheBound() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)])
        try transaction(smc).apply(percent: 70)
        smc.clearLog(); smc.failOnce = ["F1Md"]
        try transaction(smc).restoreAutomatic()
        XCTAssertEqual(smc.writes, ["F0Md=0", "F1Md=0 rejected", "F1Md=0"])
        XCTAssertEqual([smc.mode(0), smc.mode(1)], [0, 0])
    }

    func testSettleTimeIsSharedAcrossFans() {
        for count in [1, 2, 6, 10] {
            clock = Date(timeIntervalSince1970: 0)
            let smc = FakeSMC.obedient(fans: Array(repeating: (1000, 5000), count: count))
            // Firmware that never accepts manual mode: every fan reads 3 again.
            smc.afterWrite = { smc, value in if value.key.hasSuffix("Md") { smc.set(SMCEncoder.uint8(3, key: value.key)) } }
            XCTAssertThrowsError(try transaction(smc).apply(percent: 100))
            XCTAssertLessThanOrEqual(clock.timeIntervalSince1970, FanWritePlan.standard.worstCaseWrite + 0.001, "\(count) fans")
            clock = Date(timeIntervalSince1970: 0)
            smc.afterWrite = { smc, value in if value.key.hasSuffix("Md") { smc.set(SMCEncoder.uint8(1, key: value.key)) } }
            XCTAssertThrowsError(try transaction(smc).restoreAutomatic())
            XCTAssertLessThanOrEqual(clock.timeIntervalSince1970, FanWritePlan.standard.worstCaseRestore + 0.001, "\(count) fans")
        }
        XCTAssertGreaterThan(FanSafety.commandReplyTimeout, FanSafety.commandWorstCase + 4)
    }

    func testVerificationFailureNamesEachMismatchedFan() {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 6000)])
        smc.afterWrite = { smc, value in if value.key == "F1Tg" { smc.set(FakeSMC.flt("F1Tg", 1834)) } }
        XCTAssertThrowsError(try transaction(smc).apply(percent: 100)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("fan 1 expected manual mode 1 at 6000 RPM, read mode 1, target 1834 RPM"), text)
            XCTAssertFalse(text.contains("fan 0 expected"), text)
            XCTAssertTrue(text.contains("F1 Tg←6000 ok"), text)
        }
    }

    // MARK: Through the recovery policy

    /// The helper's composition over fake registers: inventory + bank + policy.
    private final class BankDriver: FanRecoveryDriver {
        let smc: FakeSMC, inventory: FanInventoryReader, transaction: () -> FanWriteTransaction
        var temperature = 70.0, clock: () -> Date
        init(_ smc: FakeSMC, clock: @escaping () -> Date, transaction: @escaping () -> FanWriteTransaction) {
            self.smc = smc; self.clock = clock; self.transaction = transaction
            inventory = FanInventoryReader(smc: smc, model: nil)
        }
        func snapshot() throws -> FanSnapshot { try inventory.read().snapshot(temperatureCelsius: temperature, sampledAt: clock()) }
        func fanSnapshot() throws -> FanReadback { FanReadback(fans: try inventory.read().fans) }
        func set(percent: Double) throws { try transaction().apply(percent: percent) }
        func restoreAutomatic() throws { try transaction().restoreAutomatic() }
        func automatic() throws -> Bool { try fanSnapshot().automatic }
    }

    private func policy(_ smc: FakeSMC) -> (FanRecoveryController, BankDriver) {
        let driver = BankDriver(smc, clock: { [unowned self] in self.clock }) { [unowned self] in self.transaction(smc) }
        return (FanRecoveryController(driver: driver, now: { [unowned self] in self.clock }), driver)
    }

    func testPartialFailureOnFan2RestoresFan1AndEveryOtherFan() {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1100, 5500), (1200, 6000)])
        smc.rejectWrites = ["F2Tg"]
        let (controller, _) = policy(smc)
        let session = UUID()
        XCTAssertThrowsError(try controller.set(percent: 90, session: session)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Fan 2 Tg write was rejected."), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.hasSuffix("Automatic control was restored and verified."), error.localizedDescription)
        }
        XCTAssertEqual(smc.writes, ["F0Md=1", "F1Md=1", "F2Md=1", "F0Tg=4500", "F1Tg=4950", "F2Tg=5400 rejected",
                                    "F0Md=0", "F1Md=0", "F2Md=0"])
        XCTAssertEqual([smc.mode(0), smc.mode(1), smc.mode(2)], [0, 0, 0])
        XCTAssertFalse(controller.state.owns(session))
    }

    func testFailedRollbackKeepsTheLeaseAndTheWatchdogFinishesIt() {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)])
        smc.rejectWrites = ["F1Tg"]
        let (controller, _) = policy(smc)
        let session = UUID()
        smc.afterWrite = { smc, value in if value.key == "F0Md" && value.bytes == [1] { smc.rejectWrites.insert("F0Md") } }
        XCTAssertThrowsError(try controller.set(percent: 90, session: session)) { error in
            XCTAssertTrue(error.localizedDescription.hasSuffix("Automatic restore did not verify yet; the helper keeps retrying."), error.localizedDescription)
        }
        XCTAssertTrue(controller.state.owns(session)); XCTAssertTrue(controller.state.restorePending)
        XCTAssertEqual(controller.ownedFans, [0, 1])
        smc.rejectWrites.removeAll(); smc.afterWrite = nil
        controller.tick()
        XCTAssertFalse(controller.state.owns(session))
        XCTAssertEqual([smc.mode(0), smc.mode(1)], [0, 0])
    }

    func testVerifiedTwoFanWriteAndWatchdogTopologyChange() throws {
        let smc = FakeSMC.obedient(fans: [(1200, 5000), (2000, 6000)])
        let (controller, _) = policy(smc)
        let session = UUID()
        let applied = try controller.set(percent: 25, session: session)
        XCTAssertEqual(applied.fans.map(\.targetPercent!), [25, 2000.0 / 6000 * 100])
        XCTAssertEqual(applied.targetPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(controller.ownedFans, [0, 1])
        controller.heartbeat(session)
        controller.tick()
        XCTAssertTrue(controller.state.owns(session), "a healthy two-fan lease stays manual")
        // FNum reports one fan, twice (a confirmed topology change): restore.
        smc.setFanCount(1)
        controller.tick(); controller.tick()
        XCTAssertFalse(controller.state.manual && controller.state.owns(session) && !controller.state.restorePending)
        XCTAssertEqual(smc.mode(0), 0)
    }

    func testUnsupportedControlPathWritesNothing() {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)]); smc.remove("F1Md")
        let (controller, _) = policy(smc)
        XCTAssertThrowsError(try controller.set(percent: 50, session: UUID())) { error in
            XCTAssertTrue(error.localizedDescription.contains("different mode registers"), error.localizedDescription)
        }
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testZeroFansCannotBeControlledButAreNotAnError() throws {
        let smc = FakeSMC(); smc.setFanCount(0)
        let (controller, driver) = policy(smc)
        XCTAssertTrue(try driver.snapshot().fans.isEmpty)
        XCTAssertThrowsError(try controller.set(percent: 50, session: UUID())) {
            guard case FanControlError.unavailable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testHighValidTemperatureNeverDisablesControlByItself() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)])
        let (controller, driver) = policy(smc)
        driver.temperature = 129
        let session = UUID()
        _ = try controller.set(percent: 100, session: session)
        controller.tick()
        XCTAssertTrue(controller.state.owns(session)); XCTAssertEqual(smc.mode(0), 1)
    }
}
