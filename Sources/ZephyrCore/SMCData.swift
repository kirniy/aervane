import Foundation

/// A four-character SMC data type, e.g. `sp78`, `flt `, `fpe2`, `ui8 `.
public struct FourCC: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ text: StaticString) {
        precondition(text.utf8CodeUnitCount == 4)
        var value: UInt32 = 0
        text.withUTF8Buffer { for byte in $0 { value = value << 8 | UInt32(byte) } }
        rawValue = value
    }
    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: rawValue >> UInt32($0)) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(format: "0x%08x", rawValue) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static let sp78 = FourCC("sp78"), flt = FourCC("flt "), fpe2 = FourCC("fpe2")
    public static let ui8 = FourCC("ui8 "), ui16 = FourCC("ui16"), flag = FourCC("flag")
}

/// One raw AppleSMC key value: its declared type and exactly its bytes.
public struct SMCValue: Sendable, Equatable {
    public let key: String
    public let dataType: FourCC
    public let bytes: [UInt8]
    public init(key: String, dataType: FourCC, bytes: [UInt8]) { self.key = key; self.dataType = dataType; self.bytes = bytes }
}

public enum SMCAccessError: Error, Equatable, LocalizedError {
    /// AppleSMC reports the key does not exist. Only this case is evidence
    /// that hardware lacks a register; every other failure may be transient.
    case notFound(String)
    /// The key exists but its type, length or value is unusable.
    case invalidData(String, String)
    /// A write the access layer refuses on principle (read-only access,
    /// unlisted key).
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let key): return "AppleSMC key \(key) does not exist."
        case let .invalidData(key, reason): return "AppleSMC key \(key) is invalid: \(reason)."
        case .refused(let key): return "AppleSMC write to \(key) was refused."
        }
    }
}

/// Raw single-key reads. Implementations perform one SMC read per call and
/// throw `SMCAccessError.notFound` only when the key is absent.
public protocol SMCKeyReading: AnyObject {
    func read(_ key: String) throws -> SMCValue
}

/// Raw single-key writes of an exact type and length.
public protocol SMCKeyWriting: SMCKeyReading {
    func write(_ value: SMCValue) throws
}

/// Typed decoders for the data types the compatibility catalog names
/// (sp78, flt, fpe2) plus the integer control registers (ui8, ui16). Every
/// decoder checks type, exact length and finiteness.
public enum SMCDecoder {
    public static func temperature(_ value: SMCValue) throws -> Double {
        let result: Double
        switch value.dataType {
        case .sp78:
            try length(value, 2)
            result = Double(Int16(bitPattern: UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))) / 256
        case .flt:
            result = Double(try float(value))
        default: throw SMCAccessError.invalidData(value.key, "type \(value.dataType) is not a temperature")
        }
        guard result.isFinite else { throw SMCAccessError.invalidData(value.key, "not finite") }
        return result
    }

    public static func fanSpeed(_ value: SMCValue) throws -> Double {
        let result: Double
        switch value.dataType {
        case .fpe2:
            try length(value, 2)
            result = Double(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])) / 4
        case .flt:
            result = Double(try float(value))
        default: throw SMCAccessError.invalidData(value.key, "type \(value.dataType) is not a fan speed")
        }
        guard result.isFinite, result >= 0 else { throw SMCAccessError.invalidData(value.key, "speed \(result) is not a finite non-negative value") }
        return result
    }

    public static func uint8(_ value: SMCValue) throws -> UInt8 {
        guard value.dataType == .ui8 else { throw SMCAccessError.invalidData(value.key, "type \(value.dataType), expected ui8") }
        try length(value, 1)
        return value.bytes[0]
    }

    /// Big-endian, as AppleSMC stores integers.
    public static func uint16(_ value: SMCValue) throws -> UInt16 {
        guard value.dataType == .ui16 else { throw SMCAccessError.invalidData(value.key, "type \(value.dataType), expected ui16") }
        try length(value, 2)
        return UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])
    }

    /// `flt ` payloads are IEEE 754 single precision, little-endian on every
    /// Mac that exposes them.
    private static func float(_ value: SMCValue) throws -> Float {
        try length(value, 4)
        let b = value.bytes
        return Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
    }

    private static func length(_ value: SMCValue, _ expected: Int) throws {
        guard value.bytes.count == expected else {
            throw SMCAccessError.invalidData(value.key, "\(value.bytes.count) bytes, expected \(expected)")
        }
    }
}

/// The aggregate `Ftst` gate of models matching requiresNewSMCKeyForManualControl:
/// exactly one byte, 1 while any fan is manual, 0 when all are automatic.
/// Only the one-byte types ui8 and flag are accepted; a write always reuses
/// the type the register reported at preflight.
public enum FtstGate {
    public static let key = "Ftst"

    public static func value(_ value: SMCValue) throws -> UInt8 {
        guard value.dataType == .ui8 || value.dataType == .flag else {
            throw SMCAccessError.invalidData(value.key, "type \(value.dataType), expected a one-byte ui8 or flag")
        }
        guard value.bytes.count == 1 else { throw SMCAccessError.invalidData(value.key, "\(value.bytes.count) bytes, expected 1") }
        guard value.bytes[0] <= 1 else { throw SMCAccessError.invalidData(value.key, "value \(value.bytes[0]), expected 0 or 1") }
        return value.bytes[0]
    }

    public static func encode(_ manual: Bool, like current: SMCValue) throws -> SMCValue {
        _ = try value(current)
        return SMCValue(key: key, dataType: current.dataType, bytes: [manual ? 1 : 0])
    }
}

public enum SMCEncoder {
    /// Encodes a fan speed in the register's own type. fpe2 is unsigned 14.2
    /// fixed point, so it cannot carry more than 16383.75 RPM.
    public static func fanSpeed(_ rpm: Double, key: String, as type: FourCC) throws -> SMCValue {
        guard rpm.isFinite, rpm >= 0 else { throw SMCAccessError.invalidData(key, "speed \(rpm) cannot be encoded") }
        switch type {
        case .fpe2:
            guard rpm <= 16383.75 else { throw SMCAccessError.invalidData(key, "speed \(rpm) exceeds fpe2") }
            let raw = UInt16((rpm * 4).rounded())
            return SMCValue(key: key, dataType: .fpe2, bytes: [UInt8(raw >> 8), UInt8(raw & 0xFF)])
        case .flt:
            let bits = Float(rpm).bitPattern
            return SMCValue(key: key, dataType: .flt, bytes: [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> UInt32($0)) })
        default:
            throw SMCAccessError.invalidData(key, "type \(type) is not a writable fan speed")
        }
    }

    public static func uint8(_ value: UInt8, key: String) -> SMCValue { SMCValue(key: key, dataType: .ui8, bytes: [value]) }
    public static func uint16(_ value: UInt16, key: String) -> SMCValue {
        SMCValue(key: key, dataType: .ui16, bytes: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }
}
