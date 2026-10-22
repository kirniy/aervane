import Foundation
import OSLog
import SMC
import ZephyrCore

struct FanHardwareReading {
    let fanCount: Int
    let currentRPM: Double; let minimumRPM: Double; let maximumRPM: Double
    let targetPercent: Double?; let automatic: Bool
}

protocol FanHardwareDriver: AnyObject {
    func snapshot() throws -> FanHardwareReading
    func hottestTemperature() throws -> Double
    func set(percent: Double) throws
    func automatic() throws
}

/// Fan 0 registers through the shared AppleSMC connection.
final class SMCFanRegisters: FanRegisterAccess {
    private let reader: SMCReader
    init(reader: SMCReader) { self.reader = reader }
    func readRegisters() throws -> FanRegisters {
        let value = try reader.readFanRegisters()
        return FanRegisters(mode: value.mode, targetRPM: value.targetRPM, actualRPM: value.actualRPM,
                            minimumRPM: value.minimumRPM, maximumRPM: value.maximumRPM)
    }
    func writeTarget(rpm: Double) throws { try reader.writeFanTarget(rpm: rpm) }
    func writeMode(_ mode: UInt8) throws { try reader.writeFanMode(mode) }
}

final class SMCFanDriver: FanHardwareDriver {
    private static let logger = Logger(subsystem: "dev.kirniy.aervane.helper", category: "smc")
    private let reader = SMCReader()
    private lazy var transaction = FanWriteTransaction(fan: SMCFanRegisters(reader: reader), plan: .standard)
    func hottestTemperature() throws -> Double { try reader.readCPUHottestTemperature() }
    func snapshot() throws -> FanHardwareReading {
        let value = try reader.readFan()
        return FanHardwareReading(fanCount: try reader.readFanCount(), currentRPM: value.currentRPM, minimumRPM: value.minimumRPM, maximumRPM: value.maximumRPM, targetPercent: value.targetPercent, automatic: value.automatic)
    }
    /// The firmware keeps an automatic mode's last target in F0Tg even though
    /// the normal snapshot intentionally hides it. Recovery journals this raw
    /// value before switching the fan to manual mode.
    func rawTargetPercent() throws -> Double {
        let registers = try reader.readFanRegisters()
        guard registers.maximumRPM.isFinite, registers.maximumRPM > 0,
              registers.targetRPM.isFinite, registers.targetRPM >= 0,
              registers.targetRPM <= registers.maximumRPM * 1.02 else {
            throw FanControlError.unavailable
        }
        return max(0, min(100, registers.targetRPM / registers.maximumRPM * 100))
    }
    func set(percent: Double) throws {
        let trace = try transaction.apply(percent: percent)
        Self.logger.info("Manual write verified: \(trace.description, privacy: .public)")
    }
    func automatic() throws {
        let trace = try transaction.restoreAutomatic()
        Self.logger.info("Automatic restore verified: \(trace.description, privacy: .public)")
    }
}
