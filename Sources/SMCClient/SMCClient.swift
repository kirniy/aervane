import Foundation
import CSMC

public struct SMCReading: Sendable { public let key: String; public let dataType: UInt32; public let bytes: [UInt8] }
public enum SMCError: Error, CustomStringConvertible, LocalizedError {
    case readFailed(String, Int32)
    public var description: String { if case let .readFailed(k,c) = self { return "AppleSMC read \(k) failed (\(c))" }; return "AppleSMC error" }
    public var errorDescription: String? { description }
}
public final class SMCReader: @unchecked Sendable {
    // The C connection is shared by all readers in this process and closes
    // when the process exits. Destroying one reader must not invalidate another.
    private let sensorLock = NSLock()
    private var cpuKeys: [String]?
    private let readOverride: ((String) throws -> SMCReading)?
    public init() { readOverride = nil }
    init(read: @escaping (String) throws -> SMCReading) { readOverride = read }
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
    public func setFanPercent(_ percent: Double, index: UInt32 = 0) throws {
        guard percent.isFinite, (0...100).contains(percent) else { throw SMCError.readFailed("fan", -1) }
        let result = zsmc_set_fan_percent(index, percent)
        guard result == 0 else { throw SMCError.readFailed("fan", result) }
    }
    public func restoreAutomatic(index: UInt32 = 0) throws {
        let result = zsmc_set_fan_automatic(index)
        guard result == 0 else { throw SMCError.readFailed("fan", result) }
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
    private func readCPUSamples() throws -> [Double] {
        sensorLock.lock()
        defer { sensorLock.unlock() }
        if cpuKeys == nil {
            // Verified M4 CPU-core key candidates. Discover once, then require
            // the entire discovered set: a failing hot core must not disappear
            // silently from the safety maximum on the next poll.
            let candidates = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e", "Te05", "Te0S", "Te09", "Te0H"]
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
