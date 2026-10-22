import XCTest
@testable import SMC
import CSMC

final class SMCTests: XCTestCase {
    private func floating(_ key: String, _ number: Float) -> SMCReading {
        var value = number
        return SMCReading(key: key, dataType: 0x666C7420, bytes: withUnsafeBytes(of: &value) { Array($0) })
    }
    func testMissingPreviouslyDiscoveredHotCoreFailsSafe() throws {
        var missingHotCore = false
        let reader = SMCReader { key in
            if key == "Tp01" { return self.floating(key, 65) }
            if key == "Tp05", !missingHotCore { return self.floating(key, 91) }
            throw SMCError.readFailed(key, -4)
        }
        XCTAssertEqual(try reader.readCPUHottestTemperature(), 91)
        missingHotCore = true
        XCTAssertThrowsError(try reader.readCPUHottestTemperature())
        XCTAssertThrowsError(try reader.readCPUTemperature())
    }
    func testIntelFallbackAlsoSupportsSafetyMaximum() throws {
        let reader = SMCReader { key in
            guard key == "TC0P" else { throw SMCError.readFailed(key, -4) }
            return self.floating(key, 74)
        }
        XCTAssertEqual(try reader.readCPUHottestTemperature(), 74)
    }
    func testMac16_10UsesAllTenMappedCPUSensorsIncludingTe0UAndTe0V() throws {
        let keys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Te05", "Te09", "Te0H", "Te0S", "Te0U", "Te0V"]
        let reader = SMCReader(read: { key in
            guard let index = keys.firstIndex(of: key) else { throw SMCError.readFailed(key, -4) }
            return self.floating(key, Float(60 + index))
        }, model: "Mac16,10")
        XCTAssertEqual(try reader.readCPUTemperature(), 64.5, accuracy: 0.001)
        XCTAssertEqual(try reader.readCPUHottestTemperature(), 69, accuracy: 0.001)
    }
    func testMac16_10GPUUsesMappedKeysOnly() throws {
        let reader = SMCReader(read: { key in
            switch key {
            case "Tg04": return self.floating(key, 70)
            case "Tg12": return self.floating(key, 74)
            case "Tg0D": return self.floating(key, 110)
            default: throw SMCError.readFailed(key, -4)
            }
        }, model: "Mac16,10")
        XCTAssertEqual(try reader.readGPUTemperature(), 72, accuracy: 0.001)
    }
    func testGPUDiscoveryRecoversAfterTransientReadFailure() throws {
        var available = false
        let reader = SMCReader(read: { key in
            guard available, key == "Tg04" else { throw SMCError.readFailed(key, -4) }
            return self.floating(key, 70)
        }, model: "Mac16,10")
        XCTAssertThrowsError(try reader.readGPUTemperature())
        available = true
        XCTAssertEqual(try reader.readGPUTemperature(), 70)
    }
    func testFanSpeedPayloadsHaveExactTypesAndLengths() throws {
        XCTAssertEqual(try SMCReader.decodeFanSpeed(SMCReading(key: "F0Ac", dataType: 0x66706532, bytes: [0x2E, 0xE0])), 3000)
        XCTAssertThrowsError(try SMCReader.decodeFanSpeed(SMCReading(key: "F0Ac", dataType: 0x66706532, bytes: [0, 1, 2])))
        XCTAssertThrowsError(try SMCReader.decodeFanSpeed(SMCReading(key: "F0Ac", dataType: 0x75693820, bytes: [50])))
    }
    func testInvalidFanModeAndBoundsAreRejected() throws {
        var invalidMode = true
        let reader = SMCReader { key in
            switch key {
            case "F0Ac": return self.floating(key, 3000)
            case "F0Mn": return self.floating(key, invalidMode ? 1000 : 6000)
            case "F0Mx": return self.floating(key, 5000)
            case "F0Md": return SMCReading(key: key, dataType: invalidMode ? 0x666C7420 : 0x75693820, bytes: [0])
            default: throw SMCError.readFailed(key, -4)
            }
        }
        XCTAssertThrowsError(try reader.readFan())
        invalidMode = false
        XCTAssertThrowsError(try reader.readFan())
    }
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
