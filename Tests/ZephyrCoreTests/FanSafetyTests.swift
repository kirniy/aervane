import XCTest
@testable import ZephyrCore

final class FanSafetyTests: XCTestCase {
    func testPercentValidation() throws { XCTAssertEqual(try FanSafety.validate(percent: 53.4), 53); XCTAssertThrowsError(try FanSafety.validate(percent: -1)); XCTAssertThrowsError(try FanSafety.validate(percent: .infinity)) }
    func testExpiredLeaseRestores() { let s = FanSnapshot(currentRPM: 2000, minimumRPM: 1000, maximumRPM: 4800, targetPercent: 40, automatic: false, temperatureCelsius: 60); XCTAssertTrue(FanSafety.shouldRestoreAutomatic(snapshot: s, lastHeartbeat: .now.addingTimeInterval(-16))) }
    func testValidHighTemperatureDoesNotRestoreWithLiveLease() { let s = FanSnapshot(currentRPM: 2000, minimumRPM: 1000, maximumRPM: 4800, targetPercent: 40, automatic: false, temperatureCelsius: 129); XCTAssertFalse(FanSafety.shouldRestoreAutomatic(snapshot: s, lastHeartbeat: .now)) }
    func testInvalidTemperatureFailsSafe() {
        XCTAssertThrowsError(try FanSafety.validateTemperature(.nan))
        XCTAssertThrowsError(try FanSafety.validateTemperature(131))
        XCTAssertEqual(try? FanSafety.validateTemperature(94.5), 94.5)
    }

    func testReadbackMustMatchRequestedPercent() {
        XCTAssertTrue(FanSafety.matchesRequestedPercent(40.5, expected: 40))
        XCTAssertFalse(FanSafety.matchesRequestedPercent(42, expected: 40))
        XCTAssertFalse(FanSafety.matchesRequestedPercent(nil, expected: 40))
    }
}
