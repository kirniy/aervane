import XCTest
@testable import ZephyrCore

/// Typed decoders and encoders. Payload cases carried over from the former
/// SMCReader decoder tests, plus the integer control registers.
final class SMCDecoderTests: XCTestCase {
    func testDecodesSp78IncludingSignedValues() throws {
        XCTAssertEqual(try SMCDecoder.temperature(SMCValue(key: "TC0P", dataType: .sp78, bytes: [0x4A, 0x80])), 74.5, accuracy: 0.001)
        XCTAssertEqual(try SMCDecoder.temperature(SMCValue(key: "TC0P", dataType: .sp78, bytes: [0xFF, 0x80])), -0.5)
    }

    func testDecodesLittleEndianFloat() throws {
        XCTAssertEqual(try SMCDecoder.temperature(SMCValue(key: "TCMb", dataType: .flt, bytes: [0x00, 0x00, 0x9A, 0x42])), 77.0, accuracy: 0.001)
    }

    func testRejectsWrongTypesLengthsAndNonFiniteValues() {
        XCTAssertThrowsError(try SMCDecoder.temperature(SMCValue(key: "FNum", dataType: .ui8, bytes: [1])))
        XCTAssertThrowsError(try SMCDecoder.temperature(SMCValue(key: "TC0P", dataType: .flt, bytes: [0])))
        XCTAssertThrowsError(try SMCDecoder.temperature(SMCValue(key: "TC0P", dataType: .sp78, bytes: [1, 2, 3])))
        XCTAssertThrowsError(try SMCDecoder.temperature(FakeSMC.flt("Tp01", .nan)))
        XCTAssertThrowsError(try SMCDecoder.temperature(FakeSMC.flt("Tp01", .infinity)))
        XCTAssertThrowsError(try SMCDecoder.fanSpeed(FakeSMC.flt("F0Ac", .nan)))
        XCTAssertThrowsError(try SMCDecoder.fanSpeed(FakeSMC.flt("F0Ac", -5)))
        XCTAssertThrowsError(try SMCDecoder.uint8(SMCValue(key: "F0Md", dataType: .ui8, bytes: [])))
        XCTAssertThrowsError(try SMCDecoder.uint8(SMCValue(key: "F0Md", dataType: .flt, bytes: [0])))
        XCTAssertThrowsError(try SMCDecoder.uint16(SMCValue(key: "FS! ", dataType: .ui16, bytes: [1])))
        XCTAssertThrowsError(try SMCDecoder.uint16(SMCValue(key: "FS! ", dataType: .ui8, bytes: [1, 2])))
    }

    func testFanSpeedPayloadsHaveExactTypesAndLengths() throws {
        XCTAssertEqual(try SMCDecoder.fanSpeed(SMCValue(key: "F0Ac", dataType: .fpe2, bytes: [0x2E, 0xE0])), 3000)
        XCTAssertThrowsError(try SMCDecoder.fanSpeed(SMCValue(key: "F0Ac", dataType: .fpe2, bytes: [0, 1, 2])))
        XCTAssertThrowsError(try SMCDecoder.fanSpeed(SMCValue(key: "F0Ac", dataType: .ui8, bytes: [50])))
    }

    func testIntegerRegistersAreBigEndian() throws {
        XCTAssertEqual(try SMCDecoder.uint8(SMCValue(key: "FNum", dataType: .ui8, bytes: [2])), 2)
        XCTAssertEqual(try SMCDecoder.uint16(SMCValue(key: "FS! ", dataType: .ui16, bytes: [0x80, 0x03])), 0x8003)
        XCTAssertEqual(SMCEncoder.uint16(0x8003, key: "FS! ").bytes, [0x80, 0x03])
    }

    func testFanSpeedEncodingRoundTripsInBothRegisterTypes() throws {
        for type in [FourCC.fpe2, .flt] {
            for rpm in [0.0, 1200, 2450.25, 5779] {
                let encoded = try SMCEncoder.fanSpeed(rpm, key: "F0Tg", as: type)
                XCTAssertEqual(encoded.dataType, type)
                XCTAssertEqual(encoded.bytes.count, type == .fpe2 ? 2 : 4)
                XCTAssertEqual(try SMCDecoder.fanSpeed(encoded), rpm, accuracy: 0.25)
            }
        }
        XCTAssertEqual(try SMCEncoder.fanSpeed(3000, key: "F0Tg", as: .fpe2).bytes, [0x2E, 0xE0])
        XCTAssertThrowsError(try SMCEncoder.fanSpeed(20_000, key: "F0Tg", as: .fpe2))
        XCTAssertThrowsError(try SMCEncoder.fanSpeed(.nan, key: "F0Tg", as: .flt))
        XCTAssertThrowsError(try SMCEncoder.fanSpeed(1000, key: "F0Tg", as: .ui16))
    }

    func testFourCCDescriptions() {
        XCTAssertEqual(FourCC.flt.description, "flt ")
        XCTAssertEqual(FourCC(rawValue: 0x66706532), .fpe2)
        XCTAssertEqual(FourCC(rawValue: 0x0000_0001).description, "0x00000001")
    }
}
