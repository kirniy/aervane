import XCTest
@testable import ZephyrCore

private final class FakeRecoveryDriver: FanRecoveryDriver {
    var snapshotValue: FanSnapshot
    var restoreCalls = 0
    var setError: Error?
    var restoreError: Error?
    var partialWriteThenError = false
    var automaticValue = false

    init(target: Double? = 40, minimum: Double = 1000, maximum: Double = 4800) {
        snapshotValue = FanSnapshot(currentRPM: 2000, minimumRPM: minimum, maximumRPM: maximum,
                                    targetPercent: target, automatic: false, temperatureCelsius: 60)
    }
    func snapshot() throws -> FanSnapshot { snapshotValue }
    func fanSnapshot() throws -> FanReadback {
        FanReadback(currentRPM: snapshotValue.currentRPM, minimumRPM: snapshotValue.minimumRPM,
                    maximumRPM: snapshotValue.maximumRPM, targetPercent: snapshotValue.targetPercent,
                    automatic: snapshotValue.automatic)
    }
    func set(percent: Double) throws {
        if partialWriteThenError {
            partialWriteThenError = false
            snapshotValue = FanSnapshot(currentRPM: 2000, minimumRPM: snapshotValue.minimumRPM,
                                        maximumRPM: snapshotValue.maximumRPM, targetPercent: percent,
                                        automatic: false, temperatureCelsius: 60)
            throw FanControlError.hardwareFailure("write acknowledgement lost")
        }
        if let setError { throw setError }
        let floor = snapshotValue.minimumRPM / snapshotValue.maximumRPM * 100
        snapshotValue = FanSnapshot(currentRPM: 2000, minimumRPM: snapshotValue.minimumRPM,
                                    maximumRPM: snapshotValue.maximumRPM, targetPercent: max(percent, floor),
                                    automatic: false, temperatureCelsius: 60)
    }
    func restoreAutomatic() throws {
        restoreCalls += 1
        if let restoreError { throw restoreError }
        automaticValue = true
        snapshotValue = FanSnapshot(currentRPM: 2000, minimumRPM: snapshotValue.minimumRPM,
                                    maximumRPM: snapshotValue.maximumRPM, targetPercent: nil,
                                    automatic: true, temperatureCelsius: 60)
    }
    func automatic() throws -> Bool { automaticValue }
}

final class FanRecoveryControllerTests: XCTestCase {
    func testSetReadbackUsesHardwareFloor() throws {
        let driver = FakeRecoveryDriver(target: nil, minimum: 1000, maximum: 4800)
        let controller = FanRecoveryController(driver: driver)
        let result = try controller.set(percent: 0, session: UUID())
        XCTAssertEqual(result.targetPercent ?? -1, 1000.0 / 4800.0 * 100, accuracy: 0.001)
        XCTAssertTrue(controller.state.manual)
    }

    func testSetFailureAttemptsRestoreAndDoesNotKeepLease() {
        let driver = FakeRecoveryDriver()
        driver.setError = FanControlError.hardwareFailure("write")
        let controller = FanRecoveryController(driver: driver)
        let session = UUID()
        XCTAssertThrowsError(try controller.set(percent: 40, session: session))
        XCTAssertEqual(driver.restoreCalls, 1)
        XCTAssertFalse(controller.state.owns(session))
    }

    func testRestoreFailureRetainsPendingLeaseForRetry() throws {
        let driver = FakeRecoveryDriver()
        let controller = FanRecoveryController(driver: driver)
        let session = UUID()
        _ = try controller.set(percent: 40, session: session)
        driver.restoreError = FanControlError.hardwareFailure("restore")
        XCTAssertThrowsError(try controller.restore(session))
        XCTAssertTrue(controller.state.owns(session))
        XCTAssertTrue(controller.state.restorePending)
        driver.restoreError = nil
        _ = try controller.restore(session)
        XCTAssertFalse(controller.state.owns(session))
    }

    func testPartialWriteKeepsLeaseWhenImmediateRestoreFails() throws {
        let driver = FakeRecoveryDriver()
        driver.partialWriteThenError = true
        driver.restoreError = FanControlError.hardwareFailure("restore unavailable")
        let controller = FanRecoveryController(driver: driver)
        let session = UUID()
        XCTAssertThrowsError(try controller.set(percent: 40, session: session))
        XCTAssertTrue(controller.state.owns(session))
        XCTAssertTrue(controller.state.restorePending)
        driver.restoreError = nil
        controller.tick()
        XCTAssertFalse(controller.state.owns(session))
    }
}
