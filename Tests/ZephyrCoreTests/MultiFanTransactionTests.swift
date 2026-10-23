import XCTest
@testable import ZephyrCore

/// REA-resolved protocol details (Ftst gate, Intel FS! precedence) and
/// restore verification through the real SMCFanBank over byte-level fake
/// registers. General multi-fan behaviour is in MultiFanControlTests.
final class MultiFanTransactionTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 0)
    private var onSleep: (() -> Void)?

    private func transaction(_ bank: FanBankAccess, _ plan: FanWritePlan = .standard) -> FanWriteTransaction {
        FanWriteTransaction(bank: bank, plan: plan, clock: { [unowned self] in self.clock },
                            sleep: { [unowned self] in self.clock.addTimeInterval($0); self.onSleep?() })
    }
    private func bank(_ smc: FakeSMC, platform: SMCPlatform? = nil, model: String? = nil) throws -> SMCFanBank {
        let inventory = try FanInventoryReader(smc: smc, model: model.map(MacModel.init(identifier:)), platform: platform).read()
        return try XCTUnwrap(SMCFanBank(smc: smc, inventory: inventory), "\(inventory.control)")
    }

    /// The helper's composition: policy + transaction + bank + inventory.
    private final class BankDriver: FanRecoveryDriver {
        let smc: FakeSMC, reader: FanInventoryReader, test: MultiFanTransactionTests
        init(_ smc: FakeSMC, _ test: MultiFanTransactionTests) { self.smc = smc; self.test = test; reader = FanInventoryReader(smc: smc, model: nil) }
        func snapshot() throws -> FanSnapshot { try reader.read().snapshot(temperatureCelsius: 70, sampledAt: test.clock) }
        func fanSnapshot() throws -> FanReadback { FanReadback(fans: try reader.read().fans) }
        private func run() throws -> FanWriteTransaction { test.transaction(try test.bank(smc)) }
        func set(percent: Double) throws { try run().apply(percent: percent) }
        func restoreAutomatic() throws { try run().restoreAutomatic() }
        func automatic() throws -> Bool { try fanSnapshot().automatic }
    }

    // MARK: Linked writes

    func testFtstIsWrittenAfterEveryModeAndBeforeTargetsThenClearedOnRestore() throws {
        let smc = FakeSMC.obedient(fans: [(1200, 5700), (1200, 6400)], scheme: .lowercase)
        smc.set(SMCValue(key: "Ftst", dataType: .flag, bytes: [0]))
        let bank = try self.bank(smc, model: "Mac17,2")
        XCTAssertTrue(bank.usesAggregateGate)
        try transaction(bank).apply(percent: 50)
        XCTAssertEqual(smc.writes, ["F0md=1", "F1md=1", "Ftst=1", "F0Tg=2850", "F1Tg=3200"])
        XCTAssertEqual(smc.registers["Ftst"], SMCValue(key: "Ftst", dataType: .flag, bytes: [1]), "the reported type is reused")
        smc.clearLog()
        try transaction(bank).restoreAutomatic()
        XCTAssertEqual(smc.writes, ["F0md=0", "F1md=0", "Ftst=0"])
    }

    func testUnusableFtstBlocksBeforeAnyWrite() throws {
        let smc = FakeSMC.obedient(fans: [(1200, 5700)], scheme: .lowercase)
        smc.set(SMCEncoder.uint8(0, key: "Ftst"))
        let bank = try self.bank(smc, model: "Mac17,2")
        smc.set(SMCEncoder.uint16(0, key: "Ftst"))   // changed type after resolution
        XCTAssertThrowsError(try transaction(bank).apply(percent: 100)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("Fan control gate Ftst is not usable. Nothing was written."), $0.localizedDescription)
        }
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testAcknowledgedButIgnoredFtstManualWriteDoesNotVerify() throws {
        let smc = FakeSMC.obedient(fans: [(1200, 5700)], scheme: .lowercase)
        smc.set(SMCValue(key: "Ftst", dataType: .flag, bytes: [0]))
        smc.afterWrite = { smc, value in
            if value.key == "Ftst" { smc.set(SMCValue(key: "Ftst", dataType: .flag, bytes: [0])) }
        }
        XCTAssertThrowsError(try transaction(try bank(smc, model: "Mac17,2")).apply(percent: 50))
        XCTAssertEqual(smc.registers["Ftst"]?.bytes, [0], "ignored gate never verifies as manual")
    }

    func testAcknowledgedButIgnoredFtstAutomaticWriteDoesNotVerify() throws {
        let smc = FakeSMC.obedient(fans: [(1200, 5700)], scheme: .lowercase)
        smc.set(SMCValue(key: "Ftst", dataType: .flag, bytes: [0]))
        let bankValue = try bank(smc, model: "Mac17,2")
        try transaction(bankValue).apply(percent: 50)
        smc.afterWrite = { smc, value in
            if value.key == "Ftst" { smc.set(SMCValue(key: "Ftst", dataType: .flag, bytes: [1])) }
        }
        XCTAssertThrowsError(try transaction(bank(smc, model: "Mac17,2")).restoreAutomatic()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Ftst"), error.localizedDescription)
        }
    }

    func testFtstStaysSetWhileAnyFanCannotBeReturnedToAuto() throws {
        let smc = FakeSMC.obedient(fans: [(1200, 5700), (1200, 6400)], scheme: .lowercase)
        smc.set(SMCEncoder.uint8(0, key: "Ftst"))
        let bank = try self.bank(smc, model: "Mac17,2")
        try transaction(bank).apply(percent: 80)
        smc.clearLog(); smc.rejectWrites = ["F1md"]
        XCTAssertThrowsError(try transaction(bank).restoreAutomatic()) {
            XCTAssertTrue($0.localizedDescription.contains("Not automatic: fan 1, Ftst."), $0.localizedDescription)
        }
        XCTAssertEqual(smc.mode(0, .lowercase), 0)
        XCTAssertEqual(smc.registers["Ftst"]?.bytes, [1], "Ftst is cleared only once every fan is commanded to Auto")
        XCTAssertFalse(smc.writes.contains("Ftst=0"))
        // Once the fan accepts Auto, the gate follows.
        smc.rejectWrites = []
        try transaction(bank).restoreAutomatic()
        XCTAssertEqual(smc.registers["Ftst"]?.bytes, [0])
    }

    func testIntelFSMaskWinsOverPerFanKeysAndPreservesUnrelatedBits() throws {
        let smc = FakeSMC.obedient(fans: [(1300, 6000), (1200, 5500)], scheme: .legacyMask, fpe2: [0, 1])
        smc.setMask(0x8004)
        smc.set(SMCEncoder.uint8(0, key: "F0Md")); smc.set(SMCEncoder.uint8(0, key: "F1Md"))
        let bank = try self.bank(smc, platform: .intel)
        XCTAssertEqual(bank.scheme, .legacyMask)
        try transaction(bank).apply(percent: 100)
        XCTAssertEqual(smc.mask, 0x8007)
        XCTAssertEqual(smc.writes, ["FS! =0x8005", "FS! =0x8007", "F0Tg=6000", "F1Tg=5500"])
        XCTAssertEqual(smc.mode(0), 0, "per-fan keys are never written once FS! is selected")
        smc.clearLog()
        try transaction(bank).restoreAutomatic()
        XCTAssertEqual(smc.mask, 0x8004)
        XCTAssertEqual(smc.writes, ["FS! =0x8006", "FS! =0x8004"])
    }

    func testAnEarlierReadbackNeverVerifiesAFanWhoseLaterReadFailed() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)])
        let bank = try self.bank(smc)
        try transaction(bank).apply(percent: 90)
        // Fan 0 rejects Auto once; fan 1 reads Auto once, then its readback fails.
        smc.failOnce = ["F0Md"]
        onSleep = { smc.transient.insert("F1Tg") }
        XCTAssertThrowsError(try transaction(bank).restoreAutomatic()) {
            XCTAssertTrue($0.localizedDescription.contains("Not automatic: fan 1."), $0.localizedDescription)
        }
        XCTAssertEqual(smc.mode(0), 0)
    }

    func testRestoreFailureKeepsTheLeasePendingThroughThePolicy() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)])
        let policy = FanRecoveryController(driver: BankDriver(smc, self), now: { [unowned self] in self.clock })
        let session = UUID()
        _ = try policy.set(percent: 60, session: session)
        smc.rejectWrites = ["F1Md"]
        XCTAssertThrowsError(try policy.restore(session))
        XCTAssertTrue(policy.state.owns(session)); XCTAssertTrue(policy.state.restorePending)
        smc.rejectWrites = []
        policy.tick()
        XCTAssertFalse(policy.state.owns(session))
        XCTAssertEqual([smc.mode(0), smc.mode(1)], [0, 0])
    }

    func testRestoreReplyIsAFreshReadingOfEveryFan() throws {
        let smc = FakeSMC.obedient(fans: [(1000, 5000), (1000, 5000)])
        let policy = FanRecoveryController(driver: BankDriver(smc, self), now: { [unowned self] in self.clock })
        let session = UUID()
        _ = try policy.set(percent: 60, session: session)
        clock.addTimeInterval(7)
        let restored = try policy.restore(session)
        XCTAssertEqual(restored.sampledAt, clock, "not the sample taken before the write")
        XCTAssertTrue(restored.automatic); XCTAssertEqual(restored.fans.map(\.index), [0, 1])
    }

    // MARK: Bounds

    func testTraceStaysBoundedForTenFans() {
        let smc = FakeSMC.obedient(fans: Array(repeating: (1000.0, 5000.0), count: 10))
        smc.afterWrite = { smc, value in if value.key.hasSuffix("Md"), value.bytes == [1] { smc.set(SMCEncoder.uint8(3, key: value.key)) } }
        XCTAssertThrowsError(try transaction(try bank(smc)).apply(percent: 100)) {
            XCTAssertLessThan($0.localizedDescription.count, 6000)
            XCTAssertTrue($0.localizedDescription.contains("fan 9 expected manual mode 1"), $0.localizedDescription)
        }
    }

    // MARK: Policy over several fans

    func testVerificationNamesEachMismatchedFan() {
        let fans = [FanReading(index: 0, currentRPM: 2000, minimumRPM: 1000, maximumRPM: 5000, targetRPM: 2500, mode: .manual),
                    FanReading(index: 1, currentRPM: 2000, minimumRPM: 2000, maximumRPM: 6000, targetRPM: nil, mode: .automatic)]
        let message = FanRecoveryController.verify(FanSnapshot(fans: fans, temperatureCelsius: 60, control: nil), requested: 50, fans: [0, 1])
        XCTAssertEqual(message, "fan 1 expected 50%, read Auto")
        XCTAssertNotNil(FanRecoveryController.verify(FanSnapshot(fans: [fans[0]], temperatureCelsius: 60, control: nil), requested: 50, fans: [0, 1]))
    }

    func testUnsupportedOrMissingFansNeverWrite() {
        let ftst = FakeSMC.obedient(fans: [(1200, 5700)], scheme: .lowercase)   // Ftst model without Ftst
        let reader = FanInventoryReader(smc: ftst, model: MacModel(identifier: "Mac17,2"))
        XCTAssertNil(SMCFanBank(smc: ftst, inventory: try! reader.read()))
        let blocked = ThrowingDriver(snapshot: try! reader.read().snapshot(temperatureCelsius: 60, sampledAt: clock))
        XCTAssertThrowsError(try FanRecoveryController(driver: blocked, now: { [unowned self] in self.clock }).set(percent: 50, session: UUID())) {
            XCTAssertTrue($0.localizedDescription.contains("Ftst"), $0.localizedDescription)
        }
        let none = ThrowingDriver(snapshot: FanSnapshot(fans: [], temperatureCelsius: 60, sampledAt: clock, control: .unavailable(.noFans)))
        XCTAssertThrowsError(try FanRecoveryController(driver: none, now: { [unowned self] in self.clock }).set(percent: 50, session: UUID())) {
            guard case FanControlError.unavailable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(blocked.writes + none.writes, 0)
        XCTAssertTrue(ftst.writes.isEmpty)
    }

    private final class ThrowingDriver: FanRecoveryDriver {
        let value: FanSnapshot; var writes = 0
        init(snapshot: FanSnapshot) { value = snapshot }
        func snapshot() throws -> FanSnapshot { value }
        func fanSnapshot() throws -> FanReadback { FanReadback(fans: value.fans) }
        func set(percent: Double) throws { writes += 1 }
        func restoreAutomatic() throws { writes += 1 }
        func automatic() throws -> Bool { value.automatic }
    }
}
