import Foundation
import SMC
import ZephyrCore

/// Independently sampled channels. A missing fan must never erase a valid
/// thermometer; fan control still requires BOTH fresh CPU and fan telemetry.
struct TelemetryReader {
    typealias CPU = (average: Double, hottest: Double)
    typealias Fan = (currentRPM: Double, minimumRPM: Double, maximumRPM: Double, targetPercent: Double?, automatic: Bool)
    var cpu: () throws -> CPU
    var fan: () throws -> Fan
    var gpu: () throws -> Double

    static func live() -> Self {
        let reader = SMCReader()
        return Self(cpu: { try reader.readCPUTemperatures() }, fan: {
            let f = try reader.readFan()
            return (f.currentRPM, f.minimumRPM, f.maximumRPM, f.targetPercent, f.automatic)
        }, gpu: { try reader.readGPUTemperature() })
    }

    func read(wantsGPU: Bool, at date: Date = Date()) -> TelemetryReading {
        // Always attempt both essential channels, regardless of either result.
        let temperatures = Result { try cpu() }
        let rotor = Result { try fan() }
        return TelemetryReading(cpu: temperatures, fan: rotor,
                                gpu: wantsGPU ? try? gpu() : nil, at: date)
    }
}

struct TelemetryReading {
    let cpu: Result<TelemetryReader.CPU, Error>
    let fan: Result<TelemetryReader.Fan, Error>
    let gpu: Double?
    let at: Date
    var fanAvailable: Bool { if case .success = fan { return true }; return false }
    var fanError: String? { if case .failure(let error) = fan { return error.localizedDescription }; return nil }
    var cpuError: String? { if case .failure(let error) = cpu { return error.localizedDescription }; return nil }
    var snapshot: FanSnapshot? {
        guard case .success(let cpu) = cpu, case .success(let fan) = fan else { return nil }
        return FanSnapshot(currentRPM: fan.currentRPM, minimumRPM: fan.minimumRPM,
                           maximumRPM: fan.maximumRPM, targetPercent: fan.targetPercent,
                           automatic: fan.automatic, temperatureCelsius: cpu.average, sampledAt: at)
    }
    var smartReading: SmartCoolingReading? {
        guard case .success(let value) = cpu else { return nil }
        return SmartCoolingReading(cpuHottest: value.hottest, gpu: gpu)
    }
    func temperature(sensor: String) -> Double? {
        guard case .success(let value) = cpu else { return nil }
        if sensor == "GPU" { return gpu }
        return sensor == "CPU" ? value.average : max(value.average, gpu ?? value.average)
    }
}
