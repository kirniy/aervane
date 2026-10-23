import Foundation
import SMC
import ZephyrCore

/// AppleSMC reads through the C client, in ZephyrCore's raw-key terms. The
/// app only reads; fan writes belong to the privileged helper.
final class SMCBridge: SMCKeyReading {
    private let reader: SMCReader
    init(reader: SMCReader = SMCReader()) { self.reader = reader }

    func read(_ key: String) throws -> SMCValue {
        do {
            let value = try reader.read(key)
            return SMCValue(key: key, dataType: FourCC(rawValue: value.dataType), bytes: value.bytes)
        } catch SMCError.notFound { throw SMCAccessError.notFound(key) }
    }

    static var model: MacModel? { SMCReader.hardwareModel().map(MacModel.init(identifier:)) }
    static var platform: SMCPlatform { SMCReader.isAppleSiliconHardware() ? .appleSilicon : .intel }
}

/// Independently sampled channels. A missing fan must never erase a valid
/// thermometer; fan control still requires BOTH fresh CPU and fan telemetry.
struct TelemetryReader {
    typealias CPU = (average: Double, hottest: Double)
    var cpu: () throws -> CPU
    /// Every fan, or an empty inventory on a fanless Mac.
    var fan: () throws -> FanInventory
    var gpu: () throws -> Double

    static func live() -> Self {
        let smc = SMCBridge(), model = SMCBridge.model
        let sensors = TemperatureSensors(smc: smc, model: model, platform: SMCBridge.platform, hid: SMCBridge.platform == .appleSilicon ? AppleSiliconHIDSource() : nil)
        let fans = FanInventoryReader(smc: smc, model: model, platform: SMCBridge.platform)
        return Self(cpu: { try sensors.readCPU() }, fan: { try fans.read() }, gpu: { try sensors.readGPUHottest() })
    }

    func read(wantsGPU: Bool, at date: Date = Date()) -> TelemetryReading {
        // Always attempt both essential channels, regardless of either result.
        let temperatures = Result { try cpu() }
        let rotor = Result { try fan() }
        var gpuValue: Double?, gpuFailure: String?
        if wantsGPU {
            do { gpuValue = try gpu() }
            catch TemperatureSensors.Failure.unavailable(.gpu) { /* No GPU sensors on this Mac. */ }
            catch { gpuFailure = error.localizedDescription }
        }
        return TelemetryReading(cpu: temperatures, fan: rotor, gpu: gpuValue, at: date, gpuFailure: gpuFailure)
    }
}

struct TelemetryReading {
    let cpu: Result<TelemetryReader.CPU, Error>
    let fan: Result<FanInventory, Error>
    let gpu: Double?
    let at: Date
    var gpuFailure: String? = nil
    /// At least one fan was read. A failed read is not "no fans".
    var fanAvailable: Bool { if case .success(let inventory) = fan { return !inventory.isEmpty }; return false }
    /// The SMC validly reports zero fans: monitoring only, and not an error.
    var fanless: Bool { if case .success(let inventory) = fan { return inventory.isEmpty }; return false }
    var fanError: String? { if case .failure(let error) = fan { return error.localizedDescription }; return nil }
    var cpuError: String? { if case .failure(let error) = cpu { return error.localizedDescription }; return nil }
    var snapshot: FanSnapshot? {
        guard case .success(let cpu) = cpu, case .success(let inventory) = fan, !inventory.isEmpty else { return nil }
        return inventory.snapshot(temperatureCelsius: cpu.average, sampledAt: at)
    }
    var smartReading: SmartCoolingReading? {
        guard case .success(let value) = cpu, gpuFailure == nil else { return nil }
        return SmartCoolingReading(cpuHottest: value.hottest, gpu: gpu)
    }
    func temperature(sensor: String) -> Double? {
        guard case .success(let value) = cpu else { return nil }
        if sensor == "GPU" { return gpu }
        return sensor == "CPU" ? value.average : max(value.average, gpu ?? value.average)
    }
}
