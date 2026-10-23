import XCTest
@testable import ZephyrHelper
import ZephyrCore

/// Fans as percentages of their own maxima; manual fans carry a target.
private final class MultiFanHardware: FanRecoveryDriver, FanRawTargetReader {
    struct Fan { var minimum: Double; var maximum: Double; var target: Double; var manual: Bool }
    var fans: [Fan]
    var restores = 0, setCalls = 0
    var setError: Error?, restoreError: Error?
    var gate: Bool?
    /// Simulates a crash between the mode writes and the target writes.
    var modesOnlyThenFail = false

    init(_ fans: [Fan]) { self.fans = fans }

    private func readings() -> [FanReading] {
        fans.enumerated().map { index, fan in
            FanReading(index: index, currentRPM: fan.minimum, minimumRPM: fan.minimum, maximumRPM: fan.maximum,
                       targetRPM: fan.manual ? fan.target * fan.maximum / 100 : nil, mode: fan.manual ? .manual : .automatic)
        }
    }
    func snapshot() throws -> FanSnapshot { FanSnapshot(fans: readings(), temperatureCelsius: 60, control: .supported(.uppercase, ftst: gate != nil), aggregateGate: gate) }
    func fanSnapshot() throws -> FanReadback { FanReadback(fans: readings(), aggregateGate: gate) }
    func rawTargetPercent() throws -> Double { fans[0].target }
    func rawTargetPercents() throws -> [Int: Double] { Dictionary(uniqueKeysWithValues: fans.enumerated().map { ($0, $1.target) }) }
    func set(percent: Double) throws {
        setCalls += 1
        for index in fans.indices { fans[index].manual = true }
        if gate != nil { gate = true }
        if modesOnlyThenFail { throw FanControlError.hardwareFailure("simulated crash after mode writes") }
        if let setError { throw setError }
        for index in fans.indices { fans[index].target = max(percent, fans[index].minimum / fans[index].maximum * 100) }
    }
    func restoreAutomatic() throws {
        restores += 1
        if let restoreError { throw restoreError }
        for index in fans.indices { fans[index].manual = false }
        if gate != nil { gate = false }
    }
    func automatic() throws -> Bool { fans.allSatisfy { !$0.manual } }
}

final class MultiFanJournalTests: XCTestCase {
    private var directory: URL!
    private var journalURL: URL { directory.appendingPathComponent("state/lease.json") }
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func twoFans() -> MultiFanHardware {
        MultiFanHardware([.init(minimum: 1200, maximum: 6000, target: 25, manual: false), .init(minimum: 2000, maximum: 5000, target: 45, manual: false)])
    }
    private func controller(_ hardware: MultiFanHardware) -> FanControlController {
        FanControlController(driver: hardware, journalURL: journalURL, requireRootJournal: false)
    }
    private func set(_ controller: FanControlController, _ percent: Double, session: UUID = UUID()) -> Error? {
        let done = expectation(description: "set"); var result: Error?
        controller.set(percent: percent, session: session) { _, error in result = error; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result
    }

    func testEveryFanIsJournaledBeforeTheFirstWrite() throws {
        let hardware = twoFans(); hardware.modesOnlyThenFail = true; hardware.restoreError = FanControlError.hardwareFailure("restore")
        let session = UUID()
        XCTAssertNotNil(set(controller(hardware), 30, session: session))
        let record = try XCTUnwrap(LeaseJournal.read(from: journalURL, requireRootOwner: false))
        XCTAssertEqual(record.schemaVersion, 2); XCTAssertEqual(record.phase, .beforeWrite)
        XCTAssertEqual(record.fans?.map(\.index), [0, 1])
        XCTAssertEqual(record.fans?.map(\.previousTargetPercent), [25, 45], "automatic fans journal their raw firmware targets")
        XCTAssertEqual(record.fans?.map(\.intendedTargetPercent), [30, 40], "each intended target is clamped to that fan's floor")
        XCTAssertEqual(record.previousTargetPercent, 25, "schema 1 fields stay readable by an older helper")
    }

    func testInterruptedTwoFanWriteIsRecoveredAndEveryFanRestored() throws {
        let hardware = twoFans(); hardware.modesOnlyThenFail = true; hardware.restoreError = FanControlError.hardwareFailure("restore")
        XCTAssertNotNil(set(controller(hardware), 30))
        XCTAssertTrue(hardware.fans.allSatisfy(\.manual))
        // Restart: fans are manual at their previous targets, which the journal attributes.
        hardware.restoreError = nil
        let restarted = controller(hardware)
        withExtendedLifetime(restarted) {
            XCTAssertTrue(hardware.fans.allSatisfy { !$0.manual })
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        }
    }

    func testAllModesAutoButFtstStillSetIsRecovered() throws {
        let hardware = twoFans(); hardware.gate = true
        let records = hardware.fans.enumerated().map { index, fan in
            FanLeaseRecord(index: index, previousTargetPercent: fan.target, intendedTargetPercent: 30)
        }
        try LeaseJournal(sessionID: UUID(), previousTargetPercent: 25, intendedPercent: 30, phase: .afterWrite,
                         processID: 1, schemaVersion: 2, fans: records, aggregateGate: false)
            .write(to: journalURL, requireRootOwner: false)
        withExtendedLifetime(controller(hardware)) {
            XCTAssertEqual(hardware.restores, 1)
            XCTAssertFalse(hardware.gate == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        }
    }

    func testTopologyExpansionWithForeignManualFanIsRejected() throws {
        let records = [FanLeaseRecord(index: 0, previousTargetPercent: 25, intendedTargetPercent: 60),
                       FanLeaseRecord(index: 1, previousTargetPercent: 45, intendedTargetPercent: 60)]
        try LeaseJournal(sessionID: UUID(), previousTargetPercent: 25, intendedPercent: 60, phase: .afterWrite,
                         processID: 1, schemaVersion: 2, fans: records).write(to: journalURL, requireRootOwner: false)
        let hardware = MultiFanHardware([
            .init(minimum: 1200, maximum: 6000, target: 60, manual: true),
            .init(minimum: 2000, maximum: 5000, target: 60, manual: true),
            .init(minimum: 1800, maximum: 5200, target: 70, manual: true)
        ])
        withExtendedLifetime(controller(hardware)) {
            XCTAssertEqual(hardware.restores, 0)
            XCTAssertTrue(hardware.fans[2].manual)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        }
    }

    func testForeignTargetOnAnyJournaledFanRelinquishesWithoutWriting() throws {
        let records = [FanLeaseRecord(index: 0, previousTargetPercent: 25, intendedTargetPercent: 60),
                       FanLeaseRecord(index: 1, previousTargetPercent: 45, intendedTargetPercent: 60)]
        try LeaseJournal(sessionID: UUID(), previousTargetPercent: 25, intendedPercent: 60, phase: .afterWrite, processID: 1,
                         schemaVersion: 2, fans: records).write(to: journalURL, requireRootOwner: false)
        let hardware = twoFans()
        hardware.fans[0].manual = true; hardware.fans[0].target = 60
        hardware.fans[1].manual = true; hardware.fans[1].target = 85   // set by someone else
        withExtendedLifetime(controller(hardware)) {
            XCTAssertEqual(hardware.restores, 0)
            XCTAssertTrue(hardware.fans.allSatisfy(\.manual))
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        }
    }

    func testTopologyChangeJudgesOnlyFansStillPresent() throws {
        let records = [FanLeaseRecord(index: 0, previousTargetPercent: 25, intendedTargetPercent: 60),
                       FanLeaseRecord(index: 1, previousTargetPercent: 45, intendedTargetPercent: 60)]
        try LeaseJournal(sessionID: UUID(), previousTargetPercent: 25, intendedPercent: 60, phase: .afterWrite, processID: 1,
                         schemaVersion: 2, fans: records).write(to: journalURL, requireRootOwner: false)
        let hardware = MultiFanHardware([.init(minimum: 1200, maximum: 6000, target: 60, manual: true)])
        withExtendedLifetime(controller(hardware)) {
            XCTAssertEqual(hardware.restores, 1)
            XCTAssertFalse(hardware.fans[0].manual)
        }
    }

    func testSchemaOneEntryOnAMultiFanMacFailsSafely() throws {
        try LeaseJournal(sessionID: UUID(), previousTargetPercent: 60, intendedPercent: 80, phase: .beforeWrite, processID: 1)
            .write(to: journalURL, requireRootOwner: false)
        let hardware = twoFans()
        hardware.fans[0].manual = true; hardware.fans[0].target = 60
        withExtendedLifetime(controller(hardware)) {
            XCTAssertEqual(hardware.restores, 0, "a single-fan record is never treated as ownership of two fans")
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        }
    }

    func testTransientReadDuringRecoveryKeepsTheRecord() throws {
        final class Flaky: FanRecoveryDriver {
            let base: MultiFanHardware; var failures = 1
            init(_ base: MultiFanHardware) { self.base = base }
            func snapshot() throws -> FanSnapshot { try base.snapshot() }
            func fanSnapshot() throws -> FanReadback {
                if failures > 0 { failures -= 1; throw FanControlError.unavailable }
                return try base.fanSnapshot()
            }
            func set(percent: Double) throws { try base.set(percent: percent) }
            func restoreAutomatic() throws { try base.restoreAutomatic() }
            func automatic() throws -> Bool { try base.automatic() }
        }
        let records = [FanLeaseRecord(index: 0, previousTargetPercent: 25, intendedTargetPercent: 60),
                       FanLeaseRecord(index: 1, previousTargetPercent: 45, intendedTargetPercent: 60)]
        try LeaseJournal(sessionID: UUID(), previousTargetPercent: 25, intendedPercent: 60, phase: .afterWrite, processID: 1,
                         schemaVersion: 2, fans: records).write(to: journalURL, requireRootOwner: false)
        let hardware = twoFans()
        for index in 0..<2 { hardware.fans[index].manual = true; hardware.fans[index].target = 60 }
        let controller = FanControlController(driver: Flaky(hardware), journalURL: journalURL, requireRootJournal: false, retryInterval: 0.02)
        withExtendedLifetime(controller) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path), "a failed read is not a topology change")
            let deadline = Date().addingTimeInterval(2)
            while hardware.restores == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            XCTAssertEqual(hardware.restores, 1)
            XCTAssertTrue(hardware.fans.allSatisfy { !$0.manual })
        }
    }

    func testJournalValidationRejectsMalformedAndUnknownSchemas() throws {
        let id = UUID()
        let duplicate = LeaseJournal(sessionID: id, previousTargetPercent: nil, intendedPercent: 50, phase: .beforeWrite, processID: 1, schemaVersion: 2,
                                     fans: [FanLeaseRecord(index: 0, previousTargetPercent: nil, intendedTargetPercent: 50),
                                            FanLeaseRecord(index: 0, previousTargetPercent: nil, intendedTargetPercent: 50)])
        XCTAssertThrowsError(try duplicate.validate())
        let future = LeaseJournal(sessionID: id, previousTargetPercent: nil, intendedPercent: 50, phase: .beforeWrite, processID: 1, schemaVersion: 3,
                                  fans: [FanLeaseRecord(index: 0, previousTargetPercent: nil, intendedTargetPercent: 50)])
        XCTAssertThrowsError(try future.validate())
        let outOfRange = LeaseJournal(sessionID: id, previousTargetPercent: nil, intendedPercent: 50, phase: .beforeWrite, processID: 1, schemaVersion: 2,
                                      fans: [FanLeaseRecord(index: 10, previousTargetPercent: nil, intendedTargetPercent: 50)])
        XCTAssertThrowsError(try outOfRange.validate())
        // An unknown schema on disk keeps the helper from claiming or controlling anything.
        let data = try JSONEncoder().encode(future)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: journalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        let hardware = twoFans()
        XCTAssertNotNil(set(controller(hardware), 50))
        XCTAssertEqual(hardware.setCalls, 0)
    }

    func testAttributionRules() {
        let manual = { (index: Int, target: Double) in
            FanReading(index: index, currentRPM: 2000, minimumRPM: 1000, maximumRPM: 5000, targetRPM: target * 50, mode: .manual)
        }
        let records = [FanLeaseRecord(index: 0, previousTargetPercent: 30, intendedTargetPercent: 70),
                       FanLeaseRecord(index: 1, previousTargetPercent: 40, intendedTargetPercent: 70)]
        XCTAssertEqual(FanControlController.attribution(records, phase: .beforeWrite, fans: [manual(0, 70), manual(1, 40)]), .owned)
        XCTAssertEqual(FanControlController.attribution(records, phase: .afterWrite, fans: [manual(0, 70), manual(1, 40)]), .foreign)
        XCTAssertEqual(FanControlController.attribution(records, phase: .afterWrite, fans: [manual(0, 70)]), .owned)
        XCTAssertEqual(FanControlController.attribution(records, phase: .afterWrite, fans: []), .unattributed)
    }
}
