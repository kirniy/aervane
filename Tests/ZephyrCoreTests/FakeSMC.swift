import Foundation
@testable import ZephyrCore

/// A byte-level AppleSMC register file. Absent keys throw `notFound`, like
/// the real C layer; `transient` keys throw a generic error; writes must
/// match the existing key's type and length, like zsmc_write_key.
final class FakeSMC: SMCKeyWriting {
    struct Transient: Error, LocalizedError { let key: String; var errorDescription: String? { "busy \(key)" } }

    var registers: [String: SMCValue] = [:]
    var transient: Set<String> = []
    /// Keys whose writes are rejected (once per entry when `failOnce`).
    var rejectWrites: Set<String> = []
    var failOnce: Set<String> = []
    private(set) var reads: [String] = []
    private(set) var writes: [String] = []
    /// Called after every accepted write, to model firmware reactions.
    var afterWrite: ((FakeSMC, SMCValue) -> Void)?

    func read(_ key: String) throws -> SMCValue {
        reads.append(key)
        if transient.contains(key) { throw Transient(key: key) }
        guard let value = registers[key] else { throw SMCAccessError.notFound(key) }
        return value
    }

    func write(_ value: SMCValue) throws {
        writes.append("\(value.key)=\(describe(value))")
        if failOnce.remove(value.key) != nil || rejectWrites.contains(value.key) {
            writes[writes.count - 1] += " rejected"
            throw SMCAccessError.refused(value.key)
        }
        guard let existing = registers[value.key] else { throw SMCAccessError.notFound(value.key) }
        guard existing.dataType == value.dataType, existing.bytes.count == value.bytes.count else {
            throw SMCAccessError.invalidData(value.key, "type/size mismatch")
        }
        registers[value.key] = value
        afterWrite?(self, value)
    }

    func clearLog() { reads.removeAll(); writes.removeAll() }

    private func describe(_ value: SMCValue) -> String {
        switch value.dataType {
        case .ui8, .flag: return String(value.bytes.first ?? 0)
        case .ui16: return "0x" + String((try? SMCDecoder.uint16(value)) ?? 0, radix: 16)
        default: return String(Int(((try? SMCDecoder.fanSpeed(value)) ?? -1).rounded()))
        }
    }

    // MARK: Builders

    static func flt(_ key: String, _ number: Float) -> SMCValue {
        let bits = number.bitPattern
        return SMCValue(key: key, dataType: .flt, bytes: [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> UInt32($0)) })
    }
    static func fpe2(_ key: String, _ rpm: Double) -> SMCValue { try! SMCEncoder.fanSpeed(rpm, key: key, as: .fpe2) }
    static func sp78(_ key: String, _ celsius: Double) -> SMCValue {
        let raw = UInt16(bitPattern: Int16((celsius * 256).rounded()))
        return SMCValue(key: key, dataType: .sp78, bytes: [UInt8(raw >> 8), UInt8(raw & 0xFF)])
    }

    func set(_ value: SMCValue) { registers[value.key] = value }
    func temperature(_ key: String, _ celsius: Double) { set(Self.flt(key, Float(celsius))) }
    func remove(_ key: String) { registers[key] = nil }

    /// A fan with its limits, mode register and target, in flt or fpe2.
    func addFan(_ index: Int, minimum: Double, maximum: Double, actual: Double? = nil, target: Double? = nil,
                mode: UInt8? = 0, scheme: FanModeScheme = .uppercase, fpe2: Bool = false) {
        func speed(_ suffix: String, _ rpm: Double) -> SMCValue {
            fpe2 ? Self.fpe2("F\(index)\(suffix)", rpm) : Self.flt("F\(index)\(suffix)", Float(rpm))
        }
        set(speed("Ac", actual ?? minimum)); set(speed("Mn", minimum)); set(speed("Mx", maximum))
        set(speed("Tg", target ?? minimum))
        if let mode, scheme != .legacyMask { set(SMCEncoder.uint8(mode, key: scheme.key(fan: index))) }
    }

    func setFanCount(_ count: UInt8) { set(SMCEncoder.uint8(count, key: "FNum")) }
    func setMask(_ mask: UInt16) { set(SMCEncoder.uint16(mask, key: "FS! ")) }
    var mask: UInt16 { (try? SMCDecoder.uint16(registers["FS! "]!)) ?? 0 }

    func mode(_ index: Int, _ scheme: FanModeScheme = .uppercase) -> UInt8? {
        registers[scheme.key(fan: index)].flatMap { try? SMCDecoder.uint8($0) }
    }
    func speed(_ key: String) -> Double? { registers[key].flatMap { try? SMCDecoder.fanSpeed($0) } }

    /// Fans that obey: a mode write takes effect at once; Ac follows Tg.
    /// `fans` holds (minimum, maximum) RPM per fan.
    static func obedient(fans: [(Double, Double)], scheme: FanModeScheme = .uppercase,
                         fpe2: Set<Int> = []) -> FakeSMC {
        let smc = FakeSMC()
        smc.setFanCount(UInt8(fans.count))
        for (index, (minimum, maximum)) in fans.enumerated() {
            smc.addFan(index, minimum: minimum, maximum: maximum, actual: minimum + 200,
                       target: minimum + 100, mode: 0, scheme: scheme, fpe2: fpe2.contains(index))
        }
        if scheme == .legacyMask { smc.setMask(0) }
        return smc
    }
}
