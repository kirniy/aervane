import Foundation
import CSMC
#if canImport(Darwin)
import Darwin
#endif

public struct SMCReading: Sendable { public let key: String; public let dataType: UInt32; public let bytes: [UInt8] }
public enum SMCError: Error, CustomStringConvertible, LocalizedError {
    case readFailed(String, Int32), writeFailed(String, Int32)
    public var description: String {
        switch self {
        case let .readFailed(k, c): return "AppleSMC read \(k) failed (\(Self.code(c)))"
        case let .writeFailed(k, c): return "AppleSMC write \(k) failed (\(Self.code(c)))"
        }
    }
    /// IOKit returns are clearer in hex (e.g. 0xe00002c2 kIOReturnBadArgument).
    private static func code(_ value: Int32) -> String { value < -1000 ? String(format: "0x%08x", UInt32(bitPattern: value)) : String(value) }
    public var errorDescription: String? { description }
}
public final class SMCReader: @unchecked Sendable {
    // The C connection is shared by all readers in this process and closes
    // when the process exits. Destroying one reader must not invalidate another.
    private let sensorLock = NSLock()
    private var cpuKeys: [String]?
    private var gpuKeys: [String]?
    private let readOverride: ((String) throws -> SMCReading)?
    private let modelIdentifier: String?
    public init() { readOverride = nil; modelIdentifier = Self.hardwareModel() }
    init(read: @escaping (String) throws -> SMCReading, model: String? = nil) {
        readOverride = read; modelIdentifier = model
    }
    private static func hardwareModel() -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
        #else
        return nil
        #endif
    }
    public func read(_ key: String) throws -> SMCReading {
        guard key.utf8.count == 4 else { throw SMCError.readFailed(key, -1) }
        if let readOverride { return try readOverride(key) }
        var bytes = [UInt8](repeating: 0, count: 32); var length = 0; var type: UInt32 = 0
        let result = bytes.withUnsafeMutableBytes { zsmc_read_key_name(key, $0.baseAddress, $0.count, &length, &type) }
        guard result == 0 else { throw SMCError.readFailed(key, result) }
        return SMCReading(key: key, dataType: type, bytes: Array(bytes.prefix(length)))
    }
    public func readTemperature(_ key: String) throws -> Double {
        let value = try read(key)
        return try Self.decodeTemperature(value)
    }
    public struct FanState: Sendable {
        public let currentRPM: Double
        public let minimumRPM: Double
        public let maximumRPM: Double
        public let targetPercent: Double?
        public let automatic: Bool
    }
    public func readFanCount() throws -> Int {
        let value = try read("FNum")
        guard value.dataType == 0x75693820, value.bytes.count == 1,
              let count = value.bytes.first, (1...10).contains(count) else { throw SMCError.readFailed("FNum", -6) }
        return Int(count)
    }
    public func readFan(_ index: UInt32 = 0) throws -> FanState {
        guard index <= 9 else { throw SMCError.readFailed("fan", -1) }
        let prefix = "F\(index)"
        let current = try readTemperatureLike("\(prefix)Ac")
        let minimum = try readTemperatureLike("\(prefix)Mn")
        let maximum = try readTemperatureLike("\(prefix)Mx")
        guard current.isFinite, current >= 0, minimum.isFinite, minimum >= 0,
              maximum.isFinite, maximum > 0, minimum <= maximum else {
            throw SMCError.readFailed(prefix, -6)
        }
        let modeValue = try read("\(prefix)Md")
        let mode = modeValue.bytes.first
        guard modeValue.dataType == 0x75693820, modeValue.bytes.count == 1,
              mode == 0 || mode == 1 || mode == 3 else {
            throw SMCError.readFailed("\(prefix)Md", -5)
        }
        // Apple firmware uses 0 for automatic control and 3 for system-managed
        // control on some generations. Both modes leave the target to SMC.
        let automatic = mode == 0 || mode == 3
        var pct: Double?
        if !automatic {
            let target = try readTemperatureLike("\(prefix)Tg")
            guard target.isFinite, target >= 0, target <= maximum * 1.02 else {
                throw SMCError.readFailed("\(prefix)Tg", -6)
            }
            pct = max(0, min(100, target / maximum * 100))
        }
        return FanState(currentRPM: current, minimumRPM: minimum, maximumRPM: maximum, targetPercent: pct, automatic: automatic)
    }
    /// Raw control registers for diagnostics and write verification. Unlike
    /// `readFan`, the target is reported in every mode.
    public func readFanRegisters(_ index: UInt32 = 0) throws -> (mode: UInt8, targetRPM: Double, actualRPM: Double, minimumRPM: Double, maximumRPM: Double) {
        guard index <= 9 else { throw SMCError.readFailed("fan", -1) }
        let prefix = "F\(index)"
        let modeValue = try read("\(prefix)Md")
        guard modeValue.dataType == 0x75693820, modeValue.bytes.count == 1, let mode = modeValue.bytes.first else {
            throw SMCError.readFailed("\(prefix)Md", -5)
        }
        let target = try readTemperatureLike("\(prefix)Tg"), actual = try readTemperatureLike("\(prefix)Ac")
        let minimum = try readTemperatureLike("\(prefix)Mn"), maximum = try readTemperatureLike("\(prefix)Mx")
        guard [target, actual, minimum, maximum].allSatisfy({ $0.isFinite && $0 >= 0 }), maximum > 0, minimum <= maximum else {
            throw SMCError.readFailed(prefix, -6)
        }
        return (mode, target, actual, minimum, maximum)
    }
    /// One AppleSMC write of F<n>Tg. Ordering and verification are the
    /// caller's responsibility (see ZephyrCore.FanWriteTransaction).
    public func writeFanTarget(rpm: Double, index: UInt32 = 0) throws {
        guard rpm.isFinite else { throw SMCError.writeFailed("F\(index)Tg", -1) }
        let result = zsmc_write_fan_target(index, rpm)
        guard result == 0 else { throw SMCError.writeFailed("F\(index)Tg", result) }
    }
    /// One AppleSMC write of F<n>Md: 0 automatic or 1 manual.
    public func writeFanMode(_ mode: UInt8, index: UInt32 = 0) throws {
        guard mode == 0 || mode == 1 else { throw SMCError.writeFailed("F\(index)Md", -1) }
        let result = zsmc_write_fan_mode(index, mode)
        guard result == 0 else { throw SMCError.writeFailed("F\(index)Md", result) }
    }
    public func readCPUTemperature() throws -> Double {
        let values = try readCPUSamples()
        return values.reduce(0, +) / Double(values.count)
    }
    public func readCPUHottestTemperature() throws -> Double {
        guard let value = try readCPUSamples().max() else {
            throw SMCError.readFailed("CPU temperature", -4)
        }
        return value
    }
    /// Average the GPU sensors mapped for the active model. On the M4 mini,
    /// Macs Fan Control maps exactly Tg04 and Tg12; unrelated legacy Tg0D/Tg0H
    /// keys must not be substituted when those mapped keys are unavailable.
    public func readGPUTemperature() throws -> Double {
        sensorLock.lock()
        defer { sensorLock.unlock() }
        if gpuKeys == nil {
            let candidates: [String]
            if modelIdentifier == "Mac16,10" {
                candidates = ["Tg04", "Tg12"]
            } else {
                candidates = ["Tg0D", "Tg0G", "Tg0H", "TG0D"]
            }
            let discovered = candidates.filter { key in
                guard let value = try? readTemperature(key) else { return false }
                return value.isFinite && (-20..<130).contains(value)
            }
            guard !discovered.isEmpty else { throw SMCError.readFailed("GPU temperature", -4) }
            gpuKeys = discovered
        }
        let values = try (gpuKeys ?? []).map { key -> Double in
            let value = try readTemperature(key)
            guard value.isFinite, (-20..<130).contains(value) else { throw SMCError.readFailed(key, -6) }
            return value
        }
        guard !values.isEmpty else { throw SMCError.readFailed("GPU temperature", -4) }
        return values.reduce(0, +) / Double(values.count)
    }
    private func readCPUSamples() throws -> [Double] {
        sensorLock.lock()
        defer { sensorLock.unlock() }
        if cpuKeys == nil {
            // Verified M4 CPU-core key candidates. Discover once, then require
            // the entire discovered set: a failing hot core must not disappear
            // silently from the safety maximum on the next poll.
            let candidates: [String]
            if modelIdentifier == "Mac16,10" {
                candidates = ["Tp01", "Tp05", "Tp09", "Tp0D", "Te05", "Te09", "Te0H", "Te0S", "Te0U", "Te0V"]
            } else {
                candidates = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e", "Te05", "Te0S", "Te09", "Te0H"]
            }
            var discovered: [String] = []
            for key in candidates {
                if let value = try? readTemperature(key) {
                    try validateCPU(value, key: key)
                    discovered.append(key)
                }
            }
            if discovered.isEmpty {
                for key in ["TC0P", "TC0D", "TCAD"] {
                    if let value = try? readTemperature(key) {
                        try validateCPU(value, key: key)
                        discovered = [key]
                        break
                    }
                }
            }
            guard !discovered.isEmpty else { throw SMCError.readFailed("CPU temperature", -4) }
            cpuKeys = discovered
        }
        return try (cpuKeys ?? []).map { key in
            let value = try readTemperature(key)
            try validateCPU(value, key: key)
            return value
        }
    }
    private func validateCPU(_ value: Double, key: String) throws {
        guard value.isFinite, (-20..<130).contains(value) else { throw SMCError.readFailed(key, -6) }
    }
    private func readTemperatureLike(_ key: String) throws -> Double {
        try Self.decodeFanSpeed(read(key))
    }
    public static func decodeFanSpeed(_ value: SMCReading) throws -> Double {
        if value.dataType == 0x66706532 {
            guard value.bytes.count == 2 else { throw SMCError.readFailed(value.key, -2) }
            return Double(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])) / 4
        }
        guard value.dataType == 0x666C7420 else { throw SMCError.readFailed(value.key, -3) }
        return try decodeTemperature(value)
    }
    public static func decodeTemperature(_ value: SMCReading) throws -> Double {
        switch value.dataType {
        case 0x73703738:
            guard value.bytes.count == 2 else { throw SMCError.readFailed(value.key, -2) }
            let raw = Int16(bitPattern: UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
            return Double(raw) / 256.0
        case 0x666C7420:
            guard value.bytes.count == 4 else { throw SMCError.readFailed(value.key, -2) }
            return Double(value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        default: throw SMCError.readFailed(value.key, -3)
        }
    }
}
