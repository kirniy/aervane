import XCTest
@testable import ZephyrHelper
import ZephyrCore

private class RecoveryHardware: FanRecoveryDriver {
    var target = 60.0
    var isAutomatic = false
    var failFanReads = 0
    var restores = 0
    var setCalls = 0
    var setError: Error?
    var restoreError: Error?
    var restored: (() -> Void)?
    func snapshot() throws -> FanSnapshot {
        FanSnapshot(currentRPM: 3000, minimumRPM: 1000, maximumRPM: 5000, targetPercent: isAutomatic ? nil : target, automatic: isAutomatic, temperatureCelsius: 60)
    }
    func fanSnapshot() throws -> FanReadback {
        if failFanReads > 0 { failFanReads -= 1; throw FanControlError.unavailable }
        return FanReadback(currentRPM: 3000, minimumRPM: 1000, maximumRPM: 5000, targetPercent: isAutomatic ? nil : target, automatic: isAutomatic)
    }
    func set(percent: Double) throws {
        setCalls += 1
        if let setError { throw setError }
        target = max(20, percent); isAutomatic = false
    }
    func restoreAutomatic() throws {
        restores += 1
        if let restoreError { throw restoreError }
        isAutomatic = true; restored?()
    }
    func automatic() throws -> Bool { isAutomatic }
}

private final class AutomaticRawTargetHardware: RecoveryHardware, FanRawTargetReader {
    var rawTarget = 60.0
    var rawReadError: Error?
    override init() {
        super.init()
        isAutomatic = true
        target = 60
    }
    override func set(percent: Double) throws {
        if let setError {
            // Model the mode-first transaction: F0Md is now manual, while
            // F0Tg remains the previous automatic target.
            setCalls += 1
            isAutomatic = false
            throw setError
        }
        try super.set(percent: percent)
    }
    func rawTargetPercent() throws -> Double {
        if let rawReadError { throw rawReadError }
        return rawTarget
    }
}

final class JournalTests: XCTestCase {
    private var directory: URL!
    private var journalURL: URL { directory.appendingPathComponent("state/lease.json") }
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func journal(_ phase: LeaseJournalPhase = .beforeWrite) -> LeaseJournal {
        LeaseJournal(sessionID: UUID(), previousTargetPercent: 60, intendedPercent: 80, phase: phase, processID: 123)
    }
    func testHeartbeatRejectsNonownerAndReleasedLease() {
        let hardware = RecoveryHardware()
        let controller = FanControlController(driver: hardware, journalURL: journalURL, requireRootJournal: false)
        let owner = UUID(), nonowner = expectation(description: "unowned heartbeat")
        controller.heartbeat(session: owner) { error in XCTAssertNotNil(error); nonowner.fulfill() }
        wait(for: [nonowner], timeout: 2)
        let set = expectation(description: "manual control")
        controller.set(percent: 60, session: owner) { _, error in XCTAssertNil(error); set.fulfill() }
        wait(for: [set], timeout: 2)
        let live = expectation(description: "owned heartbeat")
        controller.heartbeat(session: owner) { error in XCTAssertNil(error); live.fulfill() }
        wait(for: [live], timeout: 2)
        let restored = expectation(description: "automatic control")
        controller.restore(session: owner) { _, error in XCTAssertNil(error); restored.fulfill() }
        wait(for: [restored], timeout: 2)
        let released = expectation(description: "released heartbeat")
        controller.heartbeat(session: owner) { error in XCTAssertNotNil(error); released.fulfill() }
        wait(for: [released], timeout: 2)
    }
    func testRejectedSecondSessionPreservesActiveJournal() throws {
        let hardware = RecoveryHardware()
        let controller = FanControlController(driver: hardware, journalURL: journalURL, requireRootJournal: false)
        let owner = UUID(), first = expectation(description: "owner write")
        controller.set(percent: 60, session: owner) { _, error in XCTAssertNil(error); first.fulfill() }
        wait(for: [first], timeout: 2)
        let record = try XCTUnwrap(LeaseJournal.read(from: journalURL, requireRootOwner: false))
        let rejected = expectation(description: "reject second owner")
        controller.set(percent: 90, session: UUID()) { _, error in XCTAssertNotNil(error); rejected.fulfill() }
        wait(for: [rejected], timeout: 2)
        XCTAssertEqual(try LeaseJournal.read(from: journalURL, requireRootOwner: false), record)
        XCTAssertEqual(record.sessionID, owner)
    }
    func testCrashBeforeChangingOwnedTargetRestoresPreviousTarget() throws {
        try journal().write(to: journalURL, requireRootOwner: false)
        let hardware = RecoveryHardware()
        let controller = FanControlController(driver: hardware, journalURL: journalURL, requireRootJournal: false)
        withExtendedLifetime(controller) { XCTAssertEqual(hardware.restores, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path)) }
    }
    func testCommittedJournalDoesNotClaimUnrelatedPreviousTarget() throws {
        try journal(.afterWrite).write(to: journalURL, requireRootOwner: false)
        let hardware = RecoveryHardware()
        let controller = FanControlController(driver: hardware, journalURL: journalURL, requireRootJournal: false)
        withExtendedLifetime(controller) { XCTAssertEqual(hardware.restores, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path)) }
    }
    func testTransientStartupReadRetriesWithoutClientConnection() throws {
        try journal().write(to: journalURL, requireRootOwner: false)
        let hardware = RecoveryHardware(); hardware.failFanReads = 1
        let restored = expectation(description: "startup retry restores")
        hardware.restored = { restored.fulfill() }
        let controller = FanControlController(driver: hardware, journalURL: journalURL, requireRootJournal: false, retryInterval: 0.02)
        withExtendedLifetime(controller) { wait(for: [restored], timeout: 2) }
    }
    func testInsecureJournalModeIsRejected() throws {
        try journal().write(to: journalURL, requireRootOwner: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journalURL.path)
        XCTAssertThrowsError(try LeaseJournal.read(from: journalURL, requireRootOwner: false))
    }

    func testAutomaticModeJournalsRawFirmwareTargetBeforeWrite() throws {
        let hardware = AutomaticRawTargetHardware()
        hardware.setError = FanControlError.hardwareFailure("simulated crash before target")
        hardware.restoreError = FanControlError.hardwareFailure("simulated crash before target")
        let controller = FanControlController(driver: hardware, journalURL: journalURL,
                                               requireRootJournal: false)
        let session = UUID()
        let finished = expectation(description: "set returns after rollback failure")
        controller.set(percent: 100, session: session) { _, error in
            XCTAssertNotNil(error)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        let record = try XCTUnwrap(LeaseJournal.read(from: journalURL, requireRootOwner: false))
        XCTAssertEqual(try XCTUnwrap(record.previousTargetPercent), 60, accuracy: 0.001)
        XCTAssertEqual(record.phase, .beforeWrite)

        // The mode write has happened, but the target write did not. A fresh
        // helper must recognize the unchanged raw target as its own lease and
        // restore Auto instead of discarding the journal as external control.
        hardware.restoreError = nil
        let restarted = FanControlController(driver: hardware, journalURL: journalURL,
                                             requireRootJournal: false)
        withExtendedLifetime(restarted) {
            XCTAssertTrue(hardware.isAutomatic)
            XCTAssertEqual(hardware.restores, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        }
    }

    func testAutomaticRawTargetReadFailurePreventsAnyWrite() throws {
        let hardware = AutomaticRawTargetHardware()
        hardware.rawReadError = FanControlError.unavailable
        let controller = FanControlController(driver: hardware, journalURL: journalURL,
                                               requireRootJournal: false)
        let finished = expectation(description: "raw read failure")
        controller.set(percent: 100, session: UUID()) { _, error in
            XCTAssertNotNil(error)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(hardware.setCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }
}
