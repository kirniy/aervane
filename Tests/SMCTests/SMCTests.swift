import XCTest
@testable import SMC
import CSMC

/// The raw client. Decoding, sensor discovery and fan inventory moved to
/// ZephyrCore (SMCDecoderTests, TemperatureSensorsTests, FanInventoryTests).
final class SMCTests: XCTestCase {
    func testReadsPassThroughExactlyAndRejectMalformedKeys() throws {
        let reader = SMCReader { key in SMCReading(key: key, dataType: 0x75693820, bytes: [2]) }
        XCTAssertEqual(try reader.read("FNum").bytes, [2])
        XCTAssertThrowsError(try reader.read("FN"))
        XCTAssertThrowsError(try reader.read("FNumber"))
    }
    func testOnlyFanControlRegistersAreWritable() {
        for key in ["F0Tg", "F9Md", "F3md", "FS! ", "Ftst"] { XCTAssertTrue(SMCReader.isWritableControlKey(key), key) }
        for key in ["F0Mx", "F0Mn", "FNum", "Tp01", "FAMd", "F10M", "fS! ", "FS!", "ftst", "F0TG"] { XCTAssertFalse(SMCReader.isWritableControlKey(key), key) }
        XCTAssertThrowsError(try SMCReader().writeControlKey("F0Mx", dataType: 0x666C7420, bytes: [0, 0, 0, 0]))
    }
    func testNotFoundIsDistinctFromOtherFailures() {
        XCTAssertEqual(SMCReader.notFoundCode, Int32(bitPattern: 0xE000_02F0))
        XCTAssertEqual(SMCError.notFound("Ftst").description, "AppleSMC key Ftst does not exist")
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
}
