import Foundation
import SMC
import ZephyrCore

struct FanHardwareReading {
    let currentRPM: Double; let minimumRPM: Double; let maximumRPM: Double
    let targetPercent: Double?; let automatic: Bool
}

protocol FanHardwareDriver: AnyObject {
    func snapshot() throws -> FanHardwareReading
    func hottestTemperature() throws -> Double
    func set(percent: Double) throws
    func automatic() throws
}

final class SMCFanDriver: FanHardwareDriver {
    private let reader = SMCReader()
    func hottestTemperature() throws -> Double { try reader.readCPUHottestTemperature() }
    func snapshot() throws -> FanHardwareReading {
        let value = try reader.readFan()
        return FanHardwareReading(currentRPM: value.currentRPM, minimumRPM: value.minimumRPM, maximumRPM: value.maximumRPM, targetPercent: value.targetPercent, automatic: value.automatic)
    }
    func set(percent: Double) throws {
        try reader.setFanPercent(percent)
    }
    func automatic() throws {
        try reader.restoreAutomatic()
    }
}
