import XCTest
@testable import ZephyrCore

private final class ThermalDriver: FanRecoveryDriver {
    var temperature = 102.0
    var target: Double?
    var automaticMode = true
    var sampleAge: TimeInterval = 0
    var count = 1
    var maximumRPM = 4800.0
    var targetRPM = 4800.0
    var undershoot = false
    var writes = 0, restores = 0
    var clock = Date()
    func snapshot() throws -> FanSnapshot {
        FanSnapshot(currentRPM: 4800, minimumRPM: 1000, maximumRPM: maximumRPM,
                    targetPercent: automaticMode ? nil : targetRPM / maximumRPM * 100,
                    automatic: automaticMode, temperatureCelsius: temperature,
                    sampledAt: clock.addingTimeInterval(-sampleAge), fanCount: count)
    }
    func fanSnapshot() throws -> FanReadback {
        FanReadback(currentRPM: 4800, minimumRPM: 1000, maximumRPM: maximumRPM,
                    targetPercent: automaticMode ? nil : targetRPM / maximumRPM * 100, automatic: automaticMode)
    }
    func set(percent: Double) throws {
        writes += 1; automaticMode = false
        targetRPM = maximumRPM * (undershoot ? 98 : percent) / 100
    }
    func restoreAutomatic() throws { restores += 1; automaticMode = true }
    func automatic() throws -> Bool { automaticMode }
}

final class MaximumCoolingTests: XCTestCase {
    func testHotMaximumCoolingWritesJournalsAndRemainsUntilDisconnect() throws {
        let hardware = ThermalDriver(), owner = UUID()
        let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
        var journals = 0
        _ = try controller.set(percent: 100, session: owner) { _ in journals += 1 }
        XCTAssertEqual(hardware.writes, 1); XCTAssertEqual(journals, 1)
        controller.tick()
        XCTAssertEqual(hardware.restores, 0); XCTAssertTrue(controller.state.owns(owner))
        controller.disconnect(owner)
        XCTAssertTrue(hardware.automaticMode); XCTAssertFalse(controller.state.owns(owner))
    }

    func testHotLowerRequestsAreAllowed() throws {
        for requested in [21.0, 60, 99, 99.4] {
            let hardware = ThermalDriver(), owner = UUID()
            let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
            _ = try controller.set(percent: requested, session: owner)
            XCTAssertEqual(hardware.writes, 1); XCTAssertTrue(controller.state.owns(owner))
        }
    }

    func testHotReductionAppliesAndMissingHeartbeatStillRestores() throws {
        let hardware = ThermalDriver(), owner = UUID()
        let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
        _ = try controller.set(percent: 100, session: owner)
        _ = try controller.set(percent: 60, session: owner)
        XCTAssertEqual(hardware.writes, 2); XCTAssertEqual(hardware.restores, 0)
        XCTAssertTrue(controller.state.owns(owner))
        hardware.clock = hardware.clock.addingTimeInterval(16); controller.tick()
        XCTAssertEqual(hardware.restores, 1)
    }

    func testHotControlStillRequiresReliableTelemetryAndHeartbeat() throws {
        let faults: [(ThermalDriver) -> Void] = [
            { $0.temperature = .nan }, { $0.temperature = 131 }, { $0.temperature = -21 },
            { $0.sampleAge = 11 }, { $0.clock = $0.clock.addingTimeInterval(16) }, { $0.count = 2 }
        ]
        for fault in faults {
            let hardware = ThermalDriver(), owner = UUID()
            let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
            _ = try controller.set(percent: 100, session: owner)
            fault(hardware); controller.tick()
            XCTAssertEqual(hardware.restores, 1); XCTAssertFalse(controller.state.owns(owner))
        }
    }

    func testWarmingReducedSpeedRemainsManual() throws {
        let hardware = ThermalDriver(); hardware.temperature = 70
        let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
        _ = try controller.set(percent: 60, session: UUID())
        hardware.temperature = 100; controller.tick()
        XCTAssertFalse(hardware.automaticMode); XCTAssertEqual(hardware.restores, 0)
    }

    func testHighestValidTemperatureAllowsRequestedSpeed() throws {
        let hardware = ThermalDriver(); hardware.temperature = 129
        let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
        _ = try controller.set(percent: 60, session: UUID())
        controller.tick()
        XCTAssertFalse(hardware.automaticMode); XCTAssertEqual(hardware.writes, 1)
    }

    func testHotExistingOwnerCanIncreaseToMaximum() throws {
        let hardware = ThermalDriver(), owner = UUID(); hardware.temperature = 70
        let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
        _ = try controller.set(percent: 60, session: owner)
        hardware.temperature = 102
        _ = try controller.set(percent: 100, session: owner)
        XCTAssertEqual(hardware.writes, 2); XCTAssertEqual(hardware.restores, 0)
    }

    func testHotReadbackOf99PercentIsNotAcceptedAsMaximum() {
        let hardware = ThermalDriver(); hardware.undershoot = true
        let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
        XCTAssertThrowsError(try controller.set(percent: 100, session: UUID()))
        XCTAssertTrue(hardware.automaticMode); XCTAssertEqual(hardware.restores, 1)
    }

    func testObservedAutomaticModeReleasesLeaseWithoutAnotherWrite() throws {
        let hardware = ThermalDriver(), owner = UUID()
        let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
        _ = try controller.set(percent: 100, session: owner)
        hardware.automaticMode = true; controller.tick()
        XCTAssertFalse(controller.state.owns(owner)); XCTAssertEqual(hardware.restores, 0)
    }

    /// `count = 2` is an aggregate-only snapshot claiming two fans without
    /// per-fan readings; multi-fan control itself is supported (MultiFanTransactionTests).
    func testMaximumPreflightRejectsInvalidReadingsAndIncompleteFanReadings() {
        for fault: (ThermalDriver) -> Void in [{ $0.temperature = .nan }, { $0.sampleAge = 11 }, { $0.count = 2 }] {
            let hardware = ThermalDriver(); fault(hardware)
            let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
            XCTAssertThrowsError(try controller.set(percent: 100, session: UUID()))
            XCTAssertEqual(hardware.writes, 0)
        }
    }

    func testPercentageRoundsToWholeNumber() throws {
        let hardware = ThermalDriver()
        let controller = FanRecoveryController(driver: hardware, now: { hardware.clock })
        _ = try controller.set(percent: 99.5, session: UUID())
        XCTAssertEqual(hardware.targetRPM, hardware.maximumRPM)
    }
}
