import Foundation

/// Fan control registers through raw AppleSMC keys, for one resolved mode
/// scheme. Each write re-reads what it depends on (the register's type, the
/// fan's limits, the current mode or mask) immediately before writing, and
/// writes exactly one key.
public final class SMCFanBank: FanBankAccess {
    public let fanIndices: [Int]
    public let scheme: FanModeScheme
    /// Writes the aggregate Ftst gate (per-fan schemes on models matching
    /// requiresNewSMCKeyForManualControl).
    public let usesAggregateGate: Bool
    private let smc: SMCKeyWriting

    public init(smc: SMCKeyWriting, scheme: FanModeScheme, fans: [Int], ftst: Bool = false) {
        self.smc = smc; self.scheme = scheme; fanIndices = fans
        usesAggregateGate = ftst && scheme != .legacyMask
    }

    /// The bank a supported inventory describes, or nil for any other.
    public convenience init?(smc: SMCKeyWriting, inventory: FanInventory) {
        guard !inventory.fans.isEmpty, inventory.control.isSupported, let scheme = inventory.control.scheme else { return nil }
        self.init(smc: smc, scheme: scheme, fans: inventory.fans.map(\.index), ftst: inventory.control.usesFtst)
    }

    public func preflightAggregateGate() throws {
        guard usesAggregateGate else { return }
        _ = try FtstGate.value(smc.read(FtstGate.key))
    }

    /// Re-reads Ftst and writes one byte of exactly the type it reported.
    public func writeAggregateGate(manual: Bool) throws {
        guard usesAggregateGate else { return }
        try smc.write(FtstGate.encode(manual, like: smc.read(FtstGate.key)))
    }

    public func readAggregateGate() throws -> Bool? {
        guard usesAggregateGate else { return nil }
        return try FtstGate.value(smc.read(FtstGate.key)) == 1
    }

    public var modeKeyLabel: String { scheme.rawValue }

    private func speed(_ key: String) throws -> Double { try SMCDecoder.fanSpeed(smc.read(key)) }

    public func readRegisters(fan: Int) throws -> FanRegisters {
        try requireParticipant(fan)
        let mode = try readMode(fan)
        let target = try speed("F\(fan)Tg"), actual = try speed("F\(fan)Ac")
        let minimum = try speed("F\(fan)Mn"), maximum = try speed("F\(fan)Mx")
        guard maximum > 0, maximum <= FanReading.plausibleRPM, minimum <= maximum, actual <= FanReading.plausibleRPM else {
            throw SMCAccessError.invalidData("F\(fan)", "limits Mn \(minimum), Mx \(maximum), Ac \(actual)")
        }
        return FanRegisters(mode: mode, targetRPM: target, actualRPM: actual, minimumRPM: minimum, maximumRPM: maximum)
    }

    /// Writes F<n>Tg in its own encoding (flt or fpe2), only within the
    /// fan's freshly read Mn...Mx (float rounding of one RPM tolerated).
    public func writeTarget(fan: Int, rpm: Double) throws {
        try requireParticipant(fan)
        let key = "F\(fan)Tg"
        let current = try smc.read(key)
        let minimum = try speed("F\(fan)Mn"), maximum = try speed("F\(fan)Mx")
        guard rpm.isFinite, maximum > 0, minimum <= maximum, rpm >= minimum - 1, rpm <= maximum + 1 else {
            throw SMCAccessError.invalidData(key, "target \(FanWriteTrace.rpm(rpm)) outside \(FanWriteTrace.rpm(minimum))...\(FanWriteTrace.rpm(maximum))")
        }
        try smc.write(SMCEncoder.fanSpeed(max(minimum, min(maximum, rpm)), key: key, as: current.dataType))
    }

    /// Mode 0 (automatic) or 1 (manual). Per-fan registers must currently
    /// hold a known value. FS! is read-modify-write of this fan's bit only:
    /// the vendor's whole-mask [00, mask] overwrite is deliberately not
    /// copied, so high and unrelated bits survive.
    public func writeMode(fan: Int, _ mode: UInt8) throws {
        try requireParticipant(fan)
        guard mode == 0 || mode == 1 else { throw SMCAccessError.refused(scheme.key(fan: fan)) }
        let key = scheme.key(fan: fan)
        switch scheme {
        case .uppercase, .lowercase:
            let current = try SMCDecoder.uint8(smc.read(key))
            guard [0, 1, 3].contains(current) else { throw SMCAccessError.invalidData(key, "unknown mode \(current)") }
            try smc.write(SMCEncoder.uint8(mode, key: key))
        case .legacyMask:
            let current = try SMCDecoder.uint16(smc.read(key))
            let updated = FanModeMask.updating(current, fan: fan, manual: mode == 1)
            if updated != current { try smc.write(SMCEncoder.uint16(updated, key: key)) }
        }
    }

    private func readMode(_ fan: Int) throws -> UInt8 {
        switch scheme {
        case .uppercase, .lowercase: return try SMCDecoder.uint8(smc.read(scheme.key(fan: fan)))
        case .legacyMask: return FanModeMask.isManual(try SMCDecoder.uint16(smc.read(scheme.key(fan: fan))), fan: fan) ? 1 : 0
        }
    }

    private func requireParticipant(_ fan: Int) throws {
        guard fanIndices.contains(fan) else { throw SMCAccessError.refused("F\(fan)") }
    }
}
