import Foundation
import CSMC

public struct SMCReading: Sendable { public let key: String; public let dataType: UInt32; public let bytes: [UInt8] }
public enum SMCError: Error, CustomStringConvertible {
    case readFailed(String, Int32)
    public var description: String { if case let .readFailed(k,c) = self { return "AppleSMC read \(k) failed (\(c))" }; return "AppleSMC error" }
}
public final class SMCReader: @unchecked Sendable {
    public init() {}
    deinit { zsmc_close() }
    public func read(_ key: String) throws -> SMCReading {
        guard key.utf8.count == 4 else { throw SMCError.readFailed(key, -1) }
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
    public func readFan(_ index: UInt32 = 0) throws -> FanState {
        guard index <= 9 else { throw SMCError.readFailed("fan", -1) }
        let prefix = "F\(index)"
        let current = try readTemperatureLike("\(prefix)Ac")
        let minimum = try readTemperatureLike("\(prefix)Mn")
        let maximum = try readTemperatureLike("\(prefix)Mx")
        let target = try? readTemperatureLike("\(prefix)Tg")
        let mode = try read("\(prefix)Md").bytes.first
        guard mode == 0 || mode == 1 || mode == 3 else {
            throw SMCError.readFailed("\(prefix)Md", -5)
        }
        // Apple firmware uses 0 for automatic control and 3 for system-managed
        // control on some generations. Both modes leave the target to SMC.
        let automatic = mode == 0 || mode == 3
        let pct = (!automatic ? target.map { max(0, min(100, ($0 / max(1, maximum)) * 100)) } : nil)
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
        // M4 CPU core sensors are explicitly identified by the model's SMC
        // map. Average only sensors proven to be CPU cores; never substitute a
        // GPU or board sensor when the CPU set is unavailable.
        let m4CPU = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e", "Te05", "Te0S", "Te09", "Te0H"]
        let values = try m4CPU.compactMap { key -> Double? in
            guard let value = try? readTemperature(key) else { return nil }
            guard value.isFinite, (-20..<130).contains(value) else {
                throw SMCError.readFailed(key, -6)
            }
            return value
        }
        if !values.isEmpty { return values.reduce(0, +) / Double(values.count) }
        for key in ["TC0P", "TC0D", "TCAD"] {
            if let value = try? readTemperature(key) {
                guard value.isFinite, (-20..<130).contains(value) else {
                    throw SMCError.readFailed(key, -6)
                }
                return value
            }
        }
        throw SMCError.readFailed("CPU temperature", -4)
    }
    public func readCPUHottestTemperature() throws -> Double {
        let keys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e", "Te05", "Te0S", "Te09", "Te0H"]
        let values = try keys.compactMap { key -> Double? in
            guard let value = try? readTemperature(key) else { return nil }
            guard value.isFinite, (-20..<130).contains(value) else {
                throw SMCError.readFailed(key, -6)
            }
            return value
        }
        guard let hottest = values.max() else { throw SMCError.readFailed("CPU temperature", -4) }
        return hottest
    }
    private func readTemperatureLike(_ key: String) throws -> Double {
        let value = try read(key)
        guard value.dataType == 0x666C7420 else { throw SMCError.readFailed(key, -3) }
        return try Self.decodeTemperature(value)
    }
    public static func decodeTemperature(_ value: SMCReading) throws -> Double {
        switch value.dataType {
        case 0x73703738:
            guard value.bytes.count >= 2 else { throw SMCError.readFailed(value.key, -2) }
            let raw = Int16(bitPattern: UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
            return Double(raw) / 256.0
        case 0x666C7420:
            guard value.bytes.count >= 4 else { throw SMCError.readFailed(value.key, -2) }
            return Double(value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        default: throw SMCError.readFailed(value.key, -3)
        }
    }
}
