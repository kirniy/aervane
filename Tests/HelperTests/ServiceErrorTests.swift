import XCTest
import ZephyrCore
@testable import ZephyrHelper

final class ServiceErrorTests: XCTestCase {
    func testStaleSensorDescriptionSurvivesSecureNSErrorArchive() throws {
        let original = FanControlService.xpcError(FanControlError.staleSensor)
        let restored = try archiveAndRestore(original)
        XCTAssertEqual(restored.domain, "dev.kirniy.aervane.FanControl")
        XCTAssertEqual(restored.code, 3)
        XCTAssertEqual(restored.localizedDescription, FanControlError.staleSensor.errorDescription)
    }

    func testHardwareFailureDetailSurvivesSecureNSErrorArchive() throws {
        let detail = "Fan target did not verify after setting."
        let original = FanControlService.xpcError(FanControlError.hardwareFailure(detail))
        let restored = try archiveAndRestore(original)
        XCTAssertEqual(restored.code, 4)
        XCTAssertEqual(restored.localizedDescription, detail)
    }

    private func archiveAndRestore(_ error: NSError) throws -> NSError {
        let data = try NSKeyedArchiver.archivedData(withRootObject: error, requiringSecureCoding: true)
        return try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data))
    }

    func testLeaseAndTimeoutErrorsHaveDistinctWireCodes() {
        XCTAssertEqual(FanControlService.xpcError(FanControlError.timedOut).code, 7)
        XCTAssertEqual(FanControlService.xpcError(FanControlError.notOwner).code, 8)
        XCTAssertEqual(FanControlService.xpcError(FanControlError.notOwner).localizedDescription, FanControlError.notOwner.errorDescription)
    }
}
