import XCTest
@testable import SMC
import CSMC

final class SMCTests: XCTestCase {
    func testDecodesSp78() throws {
        let sample = SMCReading(key: "TC0P", dataType: 0x73703738, bytes: [0x4A, 0x80])
        XCTAssertEqual(try SMCReader.decodeTemperature(sample), 74.5, accuracy: 0.001)
    }
    func testDecodesFloat() throws {
        let sample = SMCReading(key: "TCMb", dataType: 0x666C7420, bytes: [0x00, 0x00, 0x9A, 0x42])
        XCTAssertEqual(try SMCReader.decodeTemperature(sample), 77.0, accuracy: 0.001)
    }
    func testRejectsUnknownType() {
        let sample = SMCReading(key: "FNum", dataType: 0x75693820, bytes: [1])
        XCTAssertThrowsError(try SMCReader.decodeTemperature(sample))
    }
    func testPercentIsFractionOfMaximumNotFirmwareRange() {
        var target = 0.0
        XCTAssertEqual(zsmc_target_rpm(1000, 5000, 50, &target), 0)
        XCTAssertEqual(target, 2500)
        XCTAssertEqual(zsmc_target_rpm(1000, 5000, 0, &target), 0)
        XCTAssertEqual(target, 1000)
        XCTAssertEqual(zsmc_target_rpm(0, 5000, 0, &target), 0)
        XCTAssertEqual(target, 0)
    }
    func testRejectsInvalidHardwareBoundsAndPercent() {
        var target = 0.0
        for (minimum, maximum, percent) in [(Double.nan, 5000.0, 50.0), (1000, 0, 50), (6000, 5000, 50), (-1, 5000, 50), (0, 5000, .infinity), (0, 5000, 101)] {
            XCTAssertNotEqual(zsmc_target_rpm(minimum, maximum, percent, &target), 0)
        }
    }
    func testShortAndSignedSensorPayloads() throws {
        XCTAssertThrowsError(try SMCReader.decodeTemperature(SMCReading(key: "TC0P", dataType: 0x666C7420, bytes: [0])))
        XCTAssertEqual(try SMCReader.decodeTemperature(SMCReading(key: "TC0P", dataType: 0x73703738, bytes: [0xFF, 0x80])), -0.5)
    }
}
